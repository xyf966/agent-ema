function [response,reads,observations] = inspect_case_core(caseId,release,manifestPath)
% Internal worker; paths are selected by trusted dispatcher or research tests.
response = struct('tool','inspect_case','tool_version','EMA-INSPECT-1.0', ...
    'case_id',caseId,'status','execution_error','error_code','', ...
    'input_hash','','parameter_version','','model_hash','', ...
    'preconditions',[],'result',struct(),'evidence',[], ...
    'warnings',{{}},'duration_ms',0);
reads = {};
observations = struct();
try
    require(~isempty(regexp(caseId,'^CASE-[0-9a-f]{32}$','once')),'invalid_case_id');
    manifest = jsondecode(fileread(manifestPath));
    require(strcmp(manifest.release_version,'EMA-OBS-1.0'),'invalid_registry');
    catalog = readJson('catalog.json');
    require(hasKeys(catalog,{'schema_version','cases'}),'invalid_catalog');
    require(strcmp(catalog.schema_version,'EMA-OBS-1.0'),'unsupported_contract');
    require(isstruct(catalog.cases) && all(arrayfun(@(v) ...
        hasKeys(v,{'case_id','group_id'}),catalog.cases)),'invalid_catalog');
    match = catalog.cases(strcmp({catalog.cases.case_id},caseId));
    if isempty(match)
        response.status = 'insufficient_data';
        response.error_code = 'case_not_found';
        return;
    end
    require(isscalar(match) && ~isempty(regexp(match.group_id, ...
        '^RUN-[0-9a-f]{32}$','once')),'invalid_catalog');
    meta = readJson([caseId '/metadata.json']);
    require(hasKeys(meta,{'case_id','group_id','schema_version','parameter_version', ...
        'context_id','sample_count','time_range_s','observations_sha256'}),'invalid_metadata');
    require(strcmp(meta.case_id,caseId) && strcmp(meta.group_id,match.group_id) && ...
        strcmp(meta.schema_version,'EMA-OBS-1.0') && ...
        strcmp(meta.parameter_version,'EMA-NOMINAL-1.0') && ...
        strcmp(meta.context_id,'CTX-PRESCRIBED-1.0'),'invalid_metadata');
    contract = readJson('channel_contract.json');
    context = readJson('operating_context.json');
    require(hasKeys(contract,{'schema_version','channels','input_sample_time_s', ...
        'alignment_method','phase_acquisition','phase_independence_scope','dq_transform', ...
        'speed_source','initial_reference_independent','initial_reference_status', ...
        'physical_sensor_validation'}),'invalid_contract');
    require(strcmp(contract.schema_version,'EMA-OBS-1.0') && ...
        isstruct(contract.channels) && numel(contract.channels)==7,'unsupported_contract');
    require(hasKeys(context,{'context_id','kind','time_range_s', ...
        'independent_load_measurement_available','actual_load_independently_verified', ...
        'command_record_interval_s','saved_command_interpolation_metadata', ...
        'compensation_interpolation','compensation_role','compensation_requires_explicit_selection', ...
        'default_compensation_enabled','limitation'}),'invalid_context');
    require(strcmp(context.context_id,meta.context_id) && ...
        strcmp(context.kind,'prescribed_test_command') && ...
        isequal(context.independent_load_measurement_available,false) && ...
        isequal(context.actual_load_independently_verified,false) && ...
        isequal(context.default_compensation_enabled,false) && ...
        isequal(context.compensation_requires_explicit_selection,true),'invalid_context');
    relative = [caseId '/observations.mat'];
    path = approvedPath(relative);
    require(strcmp(hashFile(path),meta.observations_sha256),'integrity_mismatch');
    header = whos('-file',path);
    require(isscalar(header) && strcmp(header.name,'observations') && ...
        strcmp(header.class,'struct') && isequal(header.size,[1 1]),'unapproved_data_structure');
    loaded = load(path,'observations');
    observations = loaded.observations;
    require(isstruct(observations) && isscalar(observations),'unapproved_data_structure');
    response.input_hash = hashText(strjoin(cellfun(@(name) ...
        [name ':' manifest.files(strcmp({manifest.files.path},name)).sha256], ...
        reads,'UniformOutput',false),'|'));
    response.parameter_version = 'EMA-NOMINAL-1.0';
    names = {'time_s','x_meas_m','omega_meas_radps','iabc_meas_A', ...
        'id_meas_A','iq_meas_A','x_ref_m'};
    units = {'s','m','rad/s','A','A','A','m'};
    widths = [1,1,1,3,1,1,1];
    kinds = {'alignment_time','simulated_position_measurement','ideal_speed_observation', ...
        'simulated_three_phase_measurement','derived_current','derived_current','position_command'};
    require(all(ismember(fieldnames(observations),names)),'unapproved_data_structure');
    channels = struct('name',{},'unit',{},'unit_matches_contract',{},'kind',{}, ...
        'present',{},'sample_count',{},'width',{},'finite',{},'aligned',{});
    dataProblem = false;
    applicabilityProblem = false;
    t = [];
    if isfield(observations,'time_s') && validArray(observations.time_s) && ...
            size(observations.time_s,2)==1 && numel(observations.time_s)>2
        t = observations.time_s;
    else
        dataProblem = true;
    end
    if ~isempty(t)
        dataProblem = dataProblem || any(~isfinite(t)) || any(diff(t)<=0);
    end
    for k = 1:7
        c = contract.channels(k);
        require(hasKeys(c,{'name','unit','width','kind','dependencies'}) && ...
            strcmp(c.name,names{k}) && strcmp(c.kind,kinds{k}),'invalid_contract');
        require(ischar(c.unit) && ismember(c.unit, ...
            {'s','m','mm','rad/s','rpm','A','mA'}),'invalid_contract');
        unitCorrect = strcmp(c.unit,units{k});
        applicabilityProblem = applicabilityProblem || ~unitCorrect || c.width~=widths(k);
        present = isfield(observations,names{k});
        n = 0; w = 0; finite = false; aligned = false;
        if present
            v = observations.(names{k});
            require(validArray(v),'unapproved_data_structure');
            n = size(v,1); w = size(v,2);
            finite = all(isfinite(v(:)));
            aligned = ~isempty(t) && n==numel(t);
            dataProblem = dataProblem || ~finite || ~aligned;
            applicabilityProblem = applicabilityProblem || w~=widths(k);
        else
            dataProblem = true;
        end
        channels(end+1) = struct('name',names{k},'unit',c.unit, ...
            'unit_matches_contract',unitCorrect,'kind',kinds{k}, ...
            'present',present,'sample_count',n,'width',w,'finite',finite,'aligned',aligned); %#ok<AGROW>
    end
    range = []; dt = []; jitter = []; timeMonotonic = false;
    if ~isempty(t) && all(isfinite(t))
        range = [t(1),t(end)];
        dt = median(diff(t)); jitter = max(abs(diff(t)-dt));
        timeMonotonic = all(diff(t)>0);
        applicabilityProblem = applicabilityProblem || ...
            abs(dt-5e-6)>=1e-10 || jitter>=1e-10 || contract.input_sample_time_s~=5e-6;
        require(meta.sample_count==numel(t) && ...
            isequal(meta.time_range_s(:),range(:)),'metadata_data_mismatch');
    end
    response.status = 'ok';
    if applicabilityProblem
        response.status = 'not_applicable';
        response.error_code = 'unsupported_sampling_units_or_width';
    end
    if dataProblem
        response.status = 'insufficient_data';
        response.error_code = 'missing_or_invalid_channel_data';
    end
    numericReady = ~dataProblem && ~applicabilityProblem;
    evId = ['EV-' hashText(['EMA-INSPECT-1.0|' caseId '|' response.input_hash])];
    phaseState = 'unknown';
    if strcmp(contract.phase_acquisition,'three_channels_not_two_phase_reconstruction')
        phaseState = 'satisfied';
    elseif strcmp(contract.phase_acquisition,'third_phase_reconstructed')
        phaseState = 'violated';
    end
    require(isequal(contract.initial_reference_independent,false) && ...
        strcmp(contract.initial_reference_status,'not_available') && ...
        isequal(contract.physical_sensor_validation,false),'invalid_contract');
    response.preconditions = [ ...
        condition('numeric_input_contract',stateOf(numericReady),evId), ...
        condition('three_phase_acquisition',phaseState,evId), ...
        condition('independent_normal_load','unknown',evId), ...
        condition('independent_initial_reference','unknown',evId)];
    response.result = struct('group_id',match.group_id,'channels',channels, ...
        'time_range_s',range,'sample_interval_s',dt,'maximum_grid_jitter_s',jitter, ...
        'time_strictly_increasing',timeMonotonic,'numeric_input_ready',numericReady, ...
        'phase_sum_interpretation_ready',numericReady && strcmp(phaseState,'satisfied'), ...
        'compensated_torque_independently_supported',false, ...
        'position_absolute_reference_available',false,'operating_context_id','CTX-PRESCRIBED-1.0');
    response.evidence = struct('id',evId,'quantity','input_quality_and_acquisition_metadata', ...
        'unit','mixed','time_range_s',range,'valid',numericReady, ...
        'source','approved_observations_and_channel_contract');
    response.warnings = {'NO_INDEPENDENT_LOAD_MEASUREMENT', ...
        'NO_INDEPENDENT_INITIAL_REFERENCE','DQ_CURRENTS_SHARE_PHASE_INPUTS', ...
        'IDEAL_SPEED_OBSERVATION','PHYSICAL_SENSOR_VALIDATION_UNAVAILABLE'};
    if ~strcmp(phaseState,'satisfied')
        response.warnings{end+1} = 'PHASE_ACQUISITION_CONDITION_UNMET';
    end
catch issue
    response.status = 'execution_error';
    response.error_code = 'internal_execution_error';
    if startsWith(issue.identifier,'Inspect:')
        response.error_code = extractAfter(issue.identifier,'Inspect:');
        if strcmp(response.error_code,'missing_artifact')
            response.status = 'insufficient_data';
        elseif strcmp(response.error_code,'unsupported_contract')
            response.status = 'not_applicable';
        end
    end
    % No exception messages, paths, unvalidated metadata, or raw arrays escape.
    response.result = struct(); response.preconditions = []; response.evidence = [];
end

    function value = readJson(name)
        value = jsondecode(fileread(approvedPath(name)));
    end

    function path = approvedPath(name)
        fixed = {'catalog.json','channel_contract.json','operating_context.json', ...
            [caseId '/metadata.json'],[caseId '/observations.mat']};
        require(ismember(name,fixed),'access_denied');
        entry = manifest.files(strcmp({manifest.files.path},name));
        require(isscalar(entry),'access_denied');
        base = char(java.io.File(release).getCanonicalPath());
        path = char(java.io.File(fullfile(release,name)).getCanonicalPath());
        require(startsWith(lower(path),lower([base filesep])),'access_denied');
        require(isfile(path),'missing_artifact');
        require(strcmp(hashFile(path),entry.sha256),'integrity_mismatch');
        reads{end+1} = name;
    end
end

function yes = hasKeys(value,names)
yes = isstruct(value) && isscalar(value) && ...
    isequal(sort(string(fieldnames(value))),sort(string(names(:))));
end

function yes = validArray(value)
yes = isa(value,'double') && isreal(value) && ismatrix(value) && ~issparse(value);
end

function require(yes,code)
assert(isscalar(yes) && yes,['Inspect:' code],'Inspection failed.');
end

function value = stateOf(yes)
value = 'violated';
if yes, value = 'satisfied'; end
end

function value = condition(name,state,id)
value = struct('name',name,'state',state,'evidence_id',id);
end

function value = hashText(text)
digest = java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(unicode2native(text,'UTF-8'),'int8'));
value = lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function value = hashFile(path)
handle = fopen(path,'rb');
require(handle>=0,'read_failed');
cleanup = onCleanup(@() fclose(handle));
digest = java.security.MessageDigest.getInstance('SHA-256');
while ~feof(handle)
    bytes = fread(handle,1024*1024,'*uint8');
    digest.update(typecast(bytes,'int8'));
end
value = lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end
