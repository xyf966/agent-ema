function response = compute_boundary_core(caseId,mode,release,manifest,evidenceRoot,algorithmPath,expectedBundleId)
% Internal numerical tool. All roots are supplied only by trusted code.
if nargin<7, expectedBundleId = ''; end
response = struct('tool','compute_residual_bundle','tool_version','EMA-BOUNDARY-RESIDUAL-1.0', ...
    'case_id',caseId,'status','execution_error','error_code','', ...
    'input_hash','','parameter_version','','model_hash','', ...
    'algorithm_version','EMA-DIAG-1.0','algorithm_hash','', ...
    'preconditions',[],'result',struct(),'evidence',[], ...
    'warnings',{{}},'duration_ms',0);
try
    require(ismember(mode,{'none','prescribed_command','recorded_assumption'}),'invalid_load_assumption');
    [inspection,~,d] = inspect_case_core(caseId,release,manifest);
    response.preconditions = inspection.preconditions;
    response.warnings = inspection.warnings;
    if ~strcmp(inspection.status,'ok')
        response.status = inspection.status;
        response.error_code = inspection.error_code;
        response.result = struct('input_inspection_status',inspection.status);
        return;
    end
    [parameters,parameterHash] = read_residual_input(release,manifest,'parameters');
    validateNominal(parameters);
    nominal = parameters.nominal;
    response.parameter_version = parameters.parameter_version;
    descriptor = jsondecode(fileread(algorithmPath));
    kernel = fullfile(fileparts(mfilename('fullpath')),'residual_kernel_v1.m');
    algorithmHash = tool_sha256(kernel,'file');
    require(strcmp(descriptor.algorithm_version,'EMA-DIAG-1.0') && ...
        strcmp(algorithmHash,descriptor.kernel_sha256),'algorithm_integrity_mismatch');
    response.algorithm_hash = algorithmHash;
    commandHash = 'not_read';
    compStatus = 'insufficient_data';
    compError = 'load_assumption_not_selected';
    d.loadKnown = false;
    if ismember(mode,{'prescribed_command','recorded_assumption'})
        try
            [command,commandHash] = read_residual_input(release,manifest,'command');
            if strcmp(mode,'recorded_assumption')
                [assumedLoad,assumptionInfo,assumptionHash] = read_boundary_assumption(release,manifest);
                command.compensation_time_s = assumedLoad.time_s;
                command.compensation_force_N = assumedLoad.external_force_N;
                command.compensation_direct_torque_Nm = assumedLoad.direct_torque_Nm;
                commandHash = tool_sha256([commandHash '|' assumptionHash '|' assumptionInfo.assumption_id],'text');
            end
            require(hasKeys(command,{'time_s','external_force_command_N', ...
                'direct_torque_command_Nm','compensation_time_s','compensation_force_N', ...
                'compensation_direct_torque_Nm'}),'unapproved_command_structure');
            good = all(structfun(@(v) isa(v,'double') && isreal(v) && ...
                iscolumn(v) && all(isfinite(v)),command));
            good = good && isequal(command.compensation_time_s,d.time_s) && ...
                isequal(size(command.compensation_force_N),size(d.time_s)) && ...
                isequal(size(command.compensation_direct_torque_Nm),size(d.time_s));
            if good
                d.loadKnown = true;
                d.external_force_known_N = command.compensation_force_N;
                d.direct_torque_known_Nm = command.compensation_direct_torque_Nm;
                compStatus = 'ok'; compError = '';
            else
                compError = 'invalid_command_data';
            end
        catch commandIssue
            if strcmp(commandIssue.identifier,'Residual:missing_artifact')
                commandHash = 'unavailable'; compError = 'command_record_unavailable';
            else
                rethrow(commandIssue);
            end
        end
    end
    response.input_hash = tool_sha256(strjoin({'EMA-BOUNDARY-RESIDUAL-1.0',caseId, ...
        inspection.input_hash,parameterHash,algorithmHash,mode,commandHash},'|'),'text');
    require(numel(d.time_s)>=2001,'insufficient_window_length');
    residuals = residual_kernel_v1(d,nominal);
    % Missing compensation is a state, never an invalid array sent to a detector.
    if ~d.loadKnown
        residuals = rmfield(residuals,'torque_known_load_Nm');
    end
    phaseReady = inspection.result.phase_sum_interpretation_ready;
    if ~phaseReady
        residuals = rmfield(residuals,'phase_sum_A');
    end
    require(~isempty(residuals.time_s),'insufficient_window_length');
    require(all(structfun(@(v) (isnumeric(v)||islogical(v)) && ...
        isreal(v) && all(isfinite(v(:))),residuals)),'nonfinite_computation');
    nValid = nnz(residuals.motion_valid);
    bundleId = ['BUNDLE-' response.input_hash];
    require(isempty(expectedBundleId) || strcmp(bundleId,expectedBundleId), ...
        'evidence_identity_mismatch');
    quantities = {'x_consistency_m','phase_sum_A','torque_uncompensated_Nm','torque_known_load_Nm'};
    units = {'m','A','N*m','N*m'};
    baseStatus = 'ok'; baseError = '';
    if nValid==0
        baseStatus = 'insufficient_data'; baseError = 'no_valid_motion_window';
    end
    channelStates = {baseStatus,baseStatus,baseStatus,compStatus};
    channelErrors = {baseError,baseError,baseError,compError};
    if ~phaseReady
        channelStates{2} = 'not_applicable'; channelErrors{2} = 'phase_acquisition_condition_unmet';
    end
    if d.loadKnown && nValid==0
        channelStates{4} = baseStatus; channelErrors{4} = baseError;
    end
    summaries = struct('quantity',{},'unit',{},'status',{},'error_code',{}, ...
        'sample_count',{},'valid_count',{},'valid_mean',{},'valid_rms',{}, ...
        'valid_max_abs',{},'evidence_id',{},'value_ref',{},'interpretation_basis',{});
    evidence = struct('id',{},'quantity',{},'unit',{},'time_range_s',{}, ...
        'valid',{},'value_ref',{},'interpretation_basis',{});
    timeRange = [residuals.time_s(1),residuals.time_s(end)];
    for k = 1:numel(quantities)
        field = quantities{k};
        id = ['EV-' response.input_hash '-' num2str(k)];
        ref = ''; meanValue = []; rmsValue = []; maxValue = [];
        count = 0; validCount = 0; basis = 'observations_and_nominal_parameters';
        if k==3, basis = 'normal_load_not_removed'; end
        if k==4
            basis = 'command_derived_compensation_assumption';
            if strcmp(mode,'recorded_assumption'), basis = 'recorded_diagnostic_assumption_not_measurement'; end
        end
        if isfield(residuals,field)
            v = residuals.(field); count = numel(v); validCount = nValid;
            ref = ['evidence://' bundleId '/' field];
            if nValid>0
                selected = v(residuals.motion_valid);
                meanValue = mean(selected); rmsValue = sqrt(mean(selected.^2));
                maxValue = max(abs(selected));
            end
            evidence(end+1) = struct('id',id,'quantity',field,'unit',units{k}, ...
                'time_range_s',timeRange,'valid',strcmp(channelStates{k},'ok'), ...
                'value_ref',ref,'interpretation_basis',basis); %#ok<AGROW>
        else
            id = '';
        end
        summaries(end+1) = struct('quantity',field,'unit',units{k}, ...
            'status',channelStates{k},'error_code',channelErrors{k}, ...
            'sample_count',count,'valid_count',validCount,'valid_mean',meanValue, ...
            'valid_rms',rmsValue,'valid_max_abs',maxValue,'evidence_id',id, ...
            'value_ref',ref,'interpretation_basis',basis); %#ok<AGROW>
    end
    stored = persistBundle(evidenceRoot,bundleId,residuals,struct( ...
        'case_id',caseId,'group_id',inspection.result.group_id,'bundle_id',bundleId, ...
        'input_hash',response.input_hash,'tool_version','EMA-BOUNDARY-RESIDUAL-1.0', ...
        'algorithm_version','EMA-DIAG-1.0','algorithm_hash',algorithmHash, ...
        'parameter_version',response.parameter_version,'load_assumption',mode, ...
        'compensation_available',d.loadKnown,'independent_load_supported',false), ...
        ~isempty(expectedBundleId));
    response.status = baseStatus; response.error_code = baseError;
    response.evidence = evidence;
    response.result = struct('bundle_id',bundleId,'bundle_ref',['evidence://' bundleId], ...
        'artifact_sha256',stored.artifact_sha256,'artifact_reused',stored.reused, ...
        'input_inspection_evidence_id',inspection.evidence.id, ...
        'load_assumption',mode,'compensation_available',d.loadKnown, ...
        'independent_load_supported',false,'channels',summaries, ...
        'output_sample_count',numel(residuals.time_s),'time_range_s',timeRange, ...
        'window_s',residuals.window_s,'output_sample_interval_s',0.001, ...
        'motion_valid_samples',nValid,'motion_valid_intervals_s',validIntervals(residuals), ...
        'partial_result',any(~strcmp(channelStates,'ok')));
    motionState = 'satisfied';
    if nValid==0, motionState = 'violated'; end
    response.preconditions(end+1) = struct('name','valid_motion_window', ...
        'state',motionState,'evidence_id',evidence(1).id);
    response.preconditions(end+1) = struct('name','command_compensation_assumption_selected', ...
        'state',stateOf(d.loadKnown),'evidence_id',inspection.evidence.id);
    if d.loadKnown
        response.warnings{end+1} = 'COMPENSATION_IS_COMMAND_ASSUMPTION';
        if strcmp(mode,'recorded_assumption')
            response.warnings{end} = 'COMPENSATION_IS_RECORDED_DIAGNOSTIC_ASSUMPTION';
        end
    else
        response.warnings{end+1} = 'COMPENSATED_TORQUE_UNAVAILABLE';
    end
    if ~phaseReady, response.warnings{end+1} = 'PHASE_SUM_RESULT_WITHHELD'; end
catch issue
    response.status = 'execution_error'; response.error_code = 'internal_execution_error';
    if startsWith(issue.identifier,'Residual:')
        response.error_code = extractAfter(issue.identifier,'Residual:');
        if ismember(response.error_code,{'missing_artifact','insufficient_window_length'})
            response.status = 'insufficient_data';
        end
    end
    response.result = struct(); response.evidence = [];
end
end

function validateNominal(p)
require(hasKeys(p,{'parameter_version','nominal'}) && ...
    strcmp(p.parameter_version,'EMA-NOMINAL-1.0') && ...
    hasKeys(p.nominal,{'motor','mechanics'}),'invalid_parameters');
require(hasKeys(p.nominal.motor,{'polePairs','flux_Wb','Ld_H','Lq_H', ...
    'rotorInertia_kgm2','viscousDamping_NmsPerRad'}) && ...
    hasKeys(p.nominal.mechanics,{'screwLead_mPerRev','gearRatio','efficiency', ...
    'coulombFriction_N','viscousFriction_NsPerM'}),'invalid_parameters');
groups = {'motor','mechanics'};
for g = 1:2
    require(all(structfun(@(v) isa(v,'double') && isscalar(v) && ...
        isreal(v) && isfinite(v) && v>=0,p.nominal.(groups{g}))),'invalid_parameters');
end
m = p.nominal.mechanics;
require(m.screwLead_mPerRev>0 && m.gearRatio>0 && m.efficiency>0 && ...
    m.efficiency<=1 && p.nominal.motor.polePairs>=1 && ...
    mod(p.nominal.motor.polePairs,1)==0,'invalid_parameters');
end

function stored = persistBundle(root,id,residuals,metadata,mustExist)
require(~isempty(regexp(id,'^BUNDLE-[0-9a-f]{64}$','once')),'invalid_evidence_id');
base = char(java.io.File(root).getCanonicalPath());
folder = char(java.io.File(fullfile(root,id)).getCanonicalPath());
require(startsWith(lower(folder),lower([base filesep])),'access_denied');
matPath = fullfile(folder,'residuals.mat');
jsonPath = fullfile(folder,'metadata.json');
if isfolder(folder)
    require(isfile(matPath) && isfile(jsonPath),'incomplete_evidence_artifact');
    prior = jsondecode(fileread(jsonPath));
    require(hasKeys(prior,[fieldnames(metadata);{'artifact_sha256'}]) && ...
        isequal(rmfield(prior,'artifact_sha256'),metadata) && ...
        strcmp(tool_sha256(matPath,'file'),prior.artifact_sha256),'evidence_integrity_mismatch');
    saved = load(matPath,'residuals');
    require(hasKeys(saved,{'residuals'}) && isequal(saved.residuals,residuals), ...
        'evidence_integrity_mismatch');
    stored = struct('artifact_sha256',prior.artifact_sha256,'reused',true);
else
    require(~mustExist,'unknown_residual_evidence');
    [ok,~] = mkdir(folder); require(ok,'evidence_write_failed');
    save(matPath,'residuals','-v7');
    metadata.artifact_sha256 = tool_sha256(matPath,'file');
    handle = fopen(jsonPath,'w','n','UTF-8'); require(handle>=0,'evidence_write_failed');
    cleanup = onCleanup(@() fclose(handle));
    fprintf(handle,'%s',jsonencode(metadata,'PrettyPrint',true));
    stored = struct('artifact_sha256',metadata.artifact_sha256,'reused',false);
end
end

function intervals = validIntervals(r)
first = find(diff([false;r.motion_valid(:)])==1);
last = find(diff([r.motion_valid(:);false])==-1);
intervals = [r.time_s(first),r.time_s(last)];
end

function yes = hasKeys(value,names)
yes = isstruct(value) && isscalar(value) && ...
    isequal(sort(string(fieldnames(value))),sort(string(names(:))));
end

function require(yes,code)
assert(isscalar(yes) && yes,['Residual:' code],'Residual tool check failed.');
end

function state = stateOf(yes)
state = 'unknown';
if yes, state = 'satisfied'; end
end
