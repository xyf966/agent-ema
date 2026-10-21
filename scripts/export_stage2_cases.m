function report = export_stage2_cases()
% Research-side exporter. Reads private sources; NEVER register for Agent use.
root = fileparts(fileparts(mfilename('fullpath')));
experiment = 'EXP-20261019-004';
out = fullfile(root,'results',experiment);
private = fullfile(root,'data','evaluation_private',experiment);
policy = jsondecode(fileread(fullfile(root,'configs','observation_export_v1.json')));
destination = fullfile(root,'data','agent_visible',policy.release_directory);
assert(~isfolder(destination),'Paper:ExistingRelease','An existing release cannot be overwritten.');
if ~isfolder(out), mkdir(out); end
if ~isfolder(private), mkdir(private); end
stage = fullfile(private,'pending_public');
if ~isfolder(stage), mkdir(stage); end
runs = {'EXP-20261016-001','EXP-20261016-002','EXP-20261016-003', ...
    'EXP-20261016-004','EXP-20261016-005','EXP-20261019-001','EXP-20261019-002'};
labels = {'healthy','F1','F2','F3','F1','F2','F3'};
profiles = {'none','step','step','step','linear_ramp','linear_ramp','linear_ramp'};
sourceManifestPath = fullfile(out,'source_hashes_before.json');
if isfile(sourceManifestPath)
    sources = jsondecode(fileread(sourceManifestPath));
else
    listing = [dir(fullfile(root,'data','**','*.mat'));dir(fullfile(root,'results','**','*.mat'))];
    sources = struct('path',{},'sha256',{});
    for k = 1:numel(listing)
        path = fullfile(listing(k).folder,listing(k).name);
        sources(end+1) = struct('path',strrep(path(numel(root)+2:end),'\','/'), ...
            'sha256',paper_file_sha256(path)); %#ok<AGROW>
    end
    writeJson(sourceManifestPath,sources);
end
assert(numel(sources)==59,'Paper:InputScope','Unexpected source dataset scope.');
mappingPath = fullfile(private,'case_mapping.json');
if isfile(mappingPath)
    mapping = jsondecode(fileread(mappingPath));
    assert(isequal(sort(string({mapping.source_run_id})),sort(string(runs))), ...
        'Paper:MappingScope','Existing mapping has a different run set.');
else
    mapping = struct('case_id',{},'group_id',{},'source_run_id',{}, ...
        'reference_class',{},'profile',{},'partition',{});
    for k = 1:numel(runs)
        mapping(end+1) = struct('case_id',opaqueId('CASE'), ...
            'group_id',opaqueId('RUN'),'source_run_id',runs{k}, ...
            'reference_class',labels{k},'profile',profiles{k}, ...
            'partition','development'); %#ok<AGROW>
    end
    [~,order] = sort({mapping.case_id});
    mapping = mapping(order);
    writeJson(mappingPath,mapping);
end
% Common external command record. Not obtained from hidden applied loads.
command.time_s = (0:0.001:0.8)';
command.external_force_command_N = zeros(size(command.time_s));
command.external_force_command_N(command.time_s>=0.02 & command.time_s<0.19) = 1500;
command.external_force_command_N(command.time_s>=0.52 & command.time_s<0.69) = -1500;
command.direct_torque_command_Nm = zeros(size(command.time_s));
command.compensation_time_s = (0:5e-6:0.8)';
command.compensation_force_N = interp1(command.time_s, ...
    command.external_force_command_N,command.compensation_time_s,'linear');
command.compensation_direct_torque_Nm = zeros(size(command.compensation_time_s));
save(fullfile(stage,'operating_context.mat'),'command','-v7');
context = struct('context_id',policy.context_id, ...
    'kind','prescribed_test_command','time_range_s',[0,0.8], ...
    'independent_load_measurement_available',false, ...
    'actual_load_independently_verified',false, ...
    'command_record_interval_s',0.001,'saved_command_interpolation_metadata','zoh', ...
    'compensation_interpolation','linear_effective_replay_alignment', ...
    'compensation_role','diagnostic_assumption_not_measurement', ...
    'compensation_requires_explicit_selection',true, ...
    'default_compensation_enabled',false, ...
    'limitation','Command records do not establish actual external load.');
writeJson(fullfile(stage,'operating_context.json'),context);
contract = makeChannelContract(policy);
writeJson(fullfile(stage,'channel_contract.json'),contract);
catalog = struct('schema_version',policy.schema_version,'cases',[]);
caseChecks = struct('case_id',{},'source_run_id',{}, ...
    'command_record_checked',{},'compensation_max_difference_N',{}, ...
    'direct_torque_max_difference_Nm',{});
sharedNominal = [];
for k = 1:numel(mapping)
    item = mapping(k);
    folder = fullfile(root,'results',item.source_run_id);
    source = load(fullfile(folder,'observations_aligned.mat'),'observations');
    observations = select_public_observations(source.observations,policy);
    truthFolder = fullfile(root,'data','evaluation_private',item.source_run_id);
    if isfile(fullfile(truthFolder,'generation.mat'))
        generation = load(fullfile(truthFolder,'generation.mat'));
        rawNominal = generation.generation.nominal;
    else
        generation = load(fullfile(truthFolder,'generation_and_evaluation.mat'));
        rawNominal = generation.config.nominal;
    end
    nominal = selectNominal(rawNominal,policy);
    if isempty(sharedNominal)
        sharedNominal = nominal;
    else
        assert(isequal(sharedNominal,nominal),'Paper:NominalDrift', ...
            'A shared parameter version requires identical nominal parameters.');
    end
    commandCheck = 'script_defined_record_checked_against_saved_setup';
    if isfile(fullfile(folder,'native_acquisition.mat'))
        raw = load(fullfile(folder,'native_acquisition.mat'),'acquisition');
        force = raw.acquisition.externalInput.getElement('ExternalForce');
        torque = raw.acquisition.externalInput.getElement('LoadTorque');
        assert(isequal(force.Time,command.time_s) && ...
            isequal(force.Data,command.external_force_command_N) && ...
            isequal(torque.Time,command.time_s) && ...
            isequal(torque.Data,command.direct_torque_command_Nm), ...
            'Paper:CommandMismatch','Saved test command differs.');
        commandCheck = 'saved_external_input_record_exact_match';
    else
        assert(strcmp(item.source_run_id,'EXP-20261016-001') && ...
            generation.generation.externalForceMagnitude_N==1500, ...
            'Paper:MissingCommand','Missing approved command source.');
    end
    forceDiff = max(abs(command.compensation_force_N-source.observations.external_force_known_N));
    torqueDiff = max(abs(command.compensation_direct_torque_Nm-source.observations.direct_torque_known_Nm));
    assert(forceDiff<1e-9 && torqueDiff==0,'Paper:CompensationAlignment', ...
        'Command-derived compensation differs from replay inputs.');
    caseChecks(end+1) = struct('case_id',item.case_id,'source_run_id',item.source_run_id, ...
        'command_record_checked',commandCheck,'compensation_max_difference_N',forceDiff, ...
        'direct_torque_max_difference_Nm',torqueDiff); %#ok<AGROW>
    caseFolder = fullfile(stage,item.case_id);
    if ~isfolder(caseFolder), mkdir(caseFolder); end
    save(fullfile(caseFolder,'observations.mat'),'observations','-v7');
    meta = struct('case_id',item.case_id,'group_id',item.group_id, ...
        'schema_version',policy.schema_version,'parameter_version',policy.parameter_version, ...
        'context_id',policy.context_id,'sample_count',numel(observations.time_s), ...
        'time_range_s',[observations.time_s(1),observations.time_s(end)], ...
        'observations_sha256',paper_file_sha256(fullfile(caseFolder,'observations.mat')));
    writeJson(fullfile(caseFolder,'metadata.json'),meta);
    catalog.cases = [catalog.cases;struct('case_id',item.case_id, ...
        'group_id',item.group_id)];
    % Evaluation side retains sources and reference outputs, never public.
    reference = load(fullfile(folder,'residuals.mat'));
    evaluationReference = struct('identity',item,'source_generation',generation, ...
        'reference_outputs',reference,'observation_source', ...
        ['results/' item.source_run_id '/observations_aligned.mat']);
    privateCase = fullfile(private,item.case_id);
    if ~isfolder(privateCase), mkdir(privateCase); end
    save(fullfile(privateCase,'evaluation_reference.mat'),'evaluationReference','-v7');
end
parameters = struct('parameter_version',policy.parameter_version,'nominal',sharedNominal);
writeJson(fullfile(stage,'parameters.json'),parameters);
writeJson(fullfile(stage,'catalog.json'),catalog);
writeJson(fullfile(out,'context_source_checks_private.json'),caseChecks);
% Test pure selector with unexpected truth fields and malformed observations.
negativeTests = runSelectionChecks(source.observations,policy);
verification = verify_stage2_export(stage,private);
after = sources;
for k = 1:numel(sources)
    after(k).sha256 = paper_file_sha256(fullfile(root,sources(k).path));
    assert(strcmp(after(k).sha256,sources(k).sha256),'Paper:SourceChanged', ...
        'An existing source MAT changed during export.');
end
writeJson(fullfile(out,'source_hashes_after.json'),after);
assert(all([negativeTests.passed]) && verification.passed,'Paper:ExportValidation', ...
    'Export checks did not pass.');
% Only a verified, fully built package is moved into the public release root.
[moved,message] = movefile(stage,destination);
assert(moved,'Paper:PublishExport','%s',message);
report = struct('experiment_id',experiment,'stage',2,'step',2,'status','passed', ...
    'schema_version',policy.schema_version,'case_count',numel(mapping), ...
    'physical_run_count',numel(mapping),'new_physical_runs',0,'agent_calls',0, ...
    'source_mat_count',numel(sources),'source_mats_unchanged',true, ...
    'maximum_command_compensation_difference_N',max([caseChecks.compensation_max_difference_N]), ...
    'verification',verification,'selector_tests',negativeTests, ...
    'public_directory',['data/agent_visible/' policy.release_directory], ...
    'tool_access_control_implemented',false,'agent_stage_completed',false, ...
    'completed_at',char(datetime('now','TimeZone','Asia/Shanghai')));
writeJson(fullfile(out,'export_validation.json'),report);
fprintf('Exported and verified %d anonymous cases; source MAT files unchanged: %d.\n', ...
    numel(mapping),numel(sources));
end

function nominal = selectNominal(source,policy)
groups = {'motor','mechanics'};
lists = {policy.motor_parameters,policy.mechanical_parameters};
nominal = struct();
for g = 1:2
    names = cellstr(string(lists{g}));
    for k = 1:numel(names)
        value = source.(groups{g}).(names{k});
        validateattributes(value,{'double'},{'scalar','real','finite','nonnegative'});
        nominal.(groups{g}).(names{k}) = value;
    end
end
end

function contract = makeChannelContract(policy)
kinds = {'alignment_time','simulated_position_measurement', ...
    'ideal_speed_observation','simulated_three_phase_measurement', ...
    'derived_current','derived_current','position_command'};
dependencies = {{},{},{},{},{'iabc_meas_A','electrical_angle'}, ...
    {'iabc_meas_A','electrical_angle'},{}};
channels = struct('name',{},'unit',{},'width',{},'kind',{},'dependencies',{});
for k = 1:numel(policy.observation_fields)
    channels(end+1) = struct('name',policy.observation_fields{k}, ...
        'unit',policy.units{k},'width',policy.observation_widths(k), ...
        'kind',kinds{k},'dependencies',dependencies(k)); %#ok<AGROW>
end
contract = struct('schema_version',policy.schema_version,'channels',channels, ...
    'input_sample_time_s',policy.input_sample_time_s, ...
    'alignment_method','unique_last_then_linear_interpolation', ...
    'phase_acquisition','three_channels_not_two_phase_reconstruction', ...
    'phase_independence_scope','channel_acquisition_not_statistical_independence', ...
    'dq_transform','Clarke_then_Park_from_same_phase_measurements', ...
    'speed_source','ideal_model_output_used_as_observation_no_sensor_dynamics', ...
    'initial_reference_independent',false, ...
    'initial_reference_status','not_available', ...
    'physical_sensor_validation',false);
end

function checks = runSelectionChecks(source,policy)
clean = select_public_observations(source,policy);
polluted = source;
polluted.config = struct('fault','secret','nested',struct('injected_value',123));
polluted.injected_unknown = ones(size(source.time_s));
checks = struct('name','unknown_truth_fields_excluded', ...
    'passed',isequal(clean,select_public_observations(polluted,policy)));
badInputs = {rmfield(source,'iq_meas_A'),source,source,source,source};
badInputs{2}.x_meas_m(2) = NaN;
badInputs{3}.iabc_meas_A = source.iabc_meas_A(:,1:2);
badInputs{4}.time_s(2) = source.time_s(1);
badInputs{5}.x_meas_m = struct('hidden',1);
names = {'missing_channel_rejected','nonfinite_rejected','wrong_width_rejected', ...
    'invalid_time_rejected','nested_channel_object_rejected'};
for k = 1:numel(badInputs)
    rejected = false;
    try
        select_public_observations(badInputs{k},policy);
    catch issue
        rejected = startsWith(issue.identifier,'Paper:');
    end
    checks(end+1) = struct('name',names{k},'passed',rejected); %#ok<AGROW>
end
end

function value = opaqueId(prefix)
id = char(java.util.UUID.randomUUID());
value = [prefix '-' strrep(id,'-','')];
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8');
assert(handle>=0,'Paper:ExportWrite','Cannot open export file.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
