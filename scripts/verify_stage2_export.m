function report = verify_stage2_export(release,private)
% Independent read-back checks. Research-only: needs original/private data.
root = fileparts(fileparts(mfilename('fullpath')));
catalog = readJson(fullfile(release,'catalog.json'));
assertKeys(catalog,{'schema_version','cases'});
assert(strcmp(catalog.schema_version,'EMA-OBS-1.0'));
mapping = readJson(fullfile(private,'case_mapping.json'));
assert(numel(catalog.cases)==7 && numel(mapping)==7);
assert(numel(unique({mapping.group_id}))==7 && numel(unique({mapping.case_id}))==7);
assert(isequal(sort(string({catalog.cases.case_id})),sort(string({mapping.case_id}))));
required = {'time_s','x_meas_m','omega_meas_radps','iabc_meas_A', ...
    'id_meas_A','iq_meas_A','x_ref_m'};
widths = [1,1,1,3,1,1,1];
units = {'s','m','rad/s','A','A','A','m'};
expected = {'catalog.json','parameters.json','channel_contract.json', ...
    'operating_context.json','operating_context.mat'};
caseChecks = struct('case_id',{},'observation_fields_equal',{}, ...
    'maximum_absolute_difference',{},'source_group_consistent',{});
parameters = readJson(fullfile(release,'parameters.json'));
assertKeys(parameters,{'parameter_version','nominal'});
assert(strcmp(parameters.parameter_version,'EMA-NOMINAL-1.0'));
assertKeys(parameters.nominal,{'motor','mechanics'});
motorNames = {'polePairs','flux_Wb','Ld_H','Lq_H','rotorInertia_kgm2','viscousDamping_NmsPerRad'};
mechanicsNames = {'screwLead_mPerRev','gearRatio','efficiency','coulombFriction_N','viscousFriction_NsPerM'};
assertKeys(parameters.nominal.motor,motorNames);
assertKeys(parameters.nominal.mechanics,mechanicsNames);
contract = readJson(fullfile(release,'channel_contract.json'));
assertKeys(contract,{'schema_version','channels','input_sample_time_s', ...
    'alignment_method','phase_acquisition','phase_independence_scope','dq_transform', ...
    'speed_source','initial_reference_independent','initial_reference_status', ...
    'physical_sensor_validation'});
assert(strcmp(contract.schema_version,'EMA-OBS-1.0'));
assert(numel(contract.channels)==7 && contract.input_sample_time_s==5e-6);
assert(~contract.initial_reference_independent && ~contract.physical_sensor_validation);
for k = 1:7
    assertKeys(contract.channels(k),{'name','unit','width','kind','dependencies'});
    assert(strcmp(contract.channels(k).name,required{k}) && ...
        strcmp(contract.channels(k).unit,units{k}) && contract.channels(k).width==widths(k));
end
context = readJson(fullfile(release,'operating_context.json'));
assertKeys(context,{'context_id','kind','time_range_s', ...
    'independent_load_measurement_available','actual_load_independently_verified', ...
    'command_record_interval_s','saved_command_interpolation_metadata', ...
    'compensation_interpolation','compensation_role','compensation_requires_explicit_selection', ...
    'default_compensation_enabled','limitation'});
assert(strcmp(context.context_id,'CTX-PRESCRIBED-1.0'));
assert(~context.independent_load_measurement_available && ...
    ~context.actual_load_independently_verified && ~context.default_compensation_enabled && ...
    context.compensation_requires_explicit_selection);
loaded = load(fullfile(release,'operating_context.mat'));
assertKeys(loaded,{'command'});
command = loaded.command;
assertKeys(command,{'time_s','external_force_command_N','direct_torque_command_Nm', ...
    'compensation_time_s','compensation_force_N','compensation_direct_torque_Nm'});
assert(all(structfun(@(v) isa(v,'double') && isreal(v) && all(isfinite(v(:))),command)));
assert(isequal(command.time_s,(0:0.001:0.8)') && ...
    isequal(command.compensation_time_s,(0:5e-6:0.8)'));
expectedForce = zeros(size(command.time_s));
expectedForce(command.time_s>=0.02 & command.time_s<0.19) = 1500;
expectedForce(command.time_s>=0.52 & command.time_s<0.69) = -1500;
assert(isequal(command.external_force_command_N,expectedForce));
assert(isequal(command.compensation_force_N, ...
    interp1(command.time_s,expectedForce,command.compensation_time_s,'linear')));
assert(isequal(command.direct_torque_command_Nm,zeros(801,1)) && ...
    isequal(command.compensation_direct_torque_Nm,zeros(160001,1)));
for k = 1:numel(catalog.cases)
    item = catalog.cases(k);
    assertKeys(item,{'case_id','group_id'});
    assert(~isempty(regexp(item.case_id,'^CASE-[0-9a-f]{32}$','once')) && ...
        ~isempty(regexp(item.group_id,'^RUN-[0-9a-f]{32}$','once')));
    match = mapping(strcmp({mapping.case_id},item.case_id));
    assert(isscalar(match) && strcmp(item.group_id,match.group_id));
    assert(strcmp(match.partition,'development'));
    expected = [expected,{[item.case_id '/observations.mat'], ...
        [item.case_id '/metadata.json']}]; %#ok<AGROW>
    folder = fullfile(release,item.case_id);
    meta = readJson(fullfile(folder,'metadata.json'));
    assertKeys(meta,{'case_id','group_id','schema_version','parameter_version', ...
        'context_id','sample_count','time_range_s','observations_sha256'});
    assert(strcmp(meta.case_id,item.case_id) && strcmp(meta.group_id,item.group_id));
    assert(strcmp(meta.schema_version,catalog.schema_version) && ...
        strcmp(meta.parameter_version,parameters.parameter_version) && ...
        strcmp(meta.context_id,context.context_id));
    assert(strcmp(meta.observations_sha256,paper_file_sha256(fullfile(folder,'observations.mat'))));
    serialized = load(fullfile(folder,'observations.mat'));
    assertKeys(serialized,{'observations'});
    assertKeys(serialized.observations,required);
    original = load(fullfile(root,'results',match.source_run_id,'observations_aligned.mat'),'observations');
    maxDifference = 0;
    for j = 1:numel(required)
        name = required{j};
        v = serialized.observations.(name);
        assert(isa(v,'double') && isreal(v) && all(isfinite(v(:))) && ...
            isequal(size(v),[160001,widths(j)]));
        assert(isequal(v,original.observations.(name)), ...
            'Paper:ExportNumericMismatch','Serialized observation changed.');
        maxDifference = max(maxDifference,max(abs(v(:)-original.observations.(name)(:))));
    end
    assert(meta.sample_count==160001 && isequal(meta.time_range_s(:),[0;0.8]));
    t = serialized.observations.time_s;
    assert(t(1)==0 && t(end)==0.8 && all(diff(t)>0) && max(abs(diff(t)-5e-6))<1e-10);
    privateFile = load(fullfile(private,item.case_id,'evaluation_reference.mat'));
    assert(isequal(privateFile.evaluationReference.identity,match));
    generation = privateFile.evaluationReference.source_generation;
    if isfield(generation,'generation')
        sourceNominal = generation.generation.nominal;
    else
        sourceNominal = generation.config.nominal;
    end
    for j = 1:numel(motorNames)
        assert(isequal(parameters.nominal.motor.(motorNames{j}),sourceNominal.motor.(motorNames{j})));
    end
    for j = 1:numel(mechanicsNames)
        assert(isequal(parameters.nominal.mechanics.(mechanicsNames{j}),sourceNominal.mechanics.(mechanicsNames{j})));
    end
    caseChecks(end+1) = struct('case_id',item.case_id,'observation_fields_equal',7, ...
        'maximum_absolute_difference',maxDifference,'source_group_consistent',true); %#ok<AGROW>
end
listing = dir(fullfile(release,'**','*'));
listing = listing(~[listing.isdir]);
actual = cell(size(listing));
hashes = struct('path',{},'sha256',{});
blocked = ['(?i)(EXP-\d{8}|(?<![a-z0-9])F[123](?![a-z0-9])|healthy|gradual|' ...
    'appliedFault|injected_|faultStart|activeMode|evaluation_private|legacy_private|[a-z]:[\\/])'];
for k = 1:numel(listing)
    path = fullfile(listing(k).folder,listing(k).name);
    actual{k} = strrep(path(numel(release)+2:end),'\','/');
    assert(isempty(regexp(actual{k},blocked,'once')));
    if endsWith(path,'.json')
        assert(isempty(regexp(fileread(path),blocked,'once')), ...
            'Paper:PublicTextLeak','Restricted text in public JSON.');
    end
    hashes(end+1) = struct('path',actual{k},'sha256',paper_file_sha256(path)); %#ok<AGROW>
end
assert(isequal(sort(string(actual(:))),sort(string(expected(:)))), ...
    'Paper:PublicFileSet','Unexpected or missing file in release.');
report = struct('passed',true,'case_checks',caseChecks, ...
    'public_file_count',numel(listing),'public_file_hashes',hashes, ...
    'raw_observation_values_changed',false,'nominal_parameters_identical',true, ...
    'unknown_public_fields_rejected',true,'public_text_scan_passed',true, ...
    'private_run_group_mapping_checked',true,'command_context_is_independent_measurement',false);
fprintf('Read-back verification passed: %d cases, %d allowed public files.\n',numel(caseChecks),numel(listing));
end

function assertKeys(value,allowed)
assert(isstruct(value) && isscalar(value) && ...
    isequal(sort(string(fieldnames(value))),sort(string(allowed(:)))), ...
    'Paper:UnexpectedPublicFields','Unexpected or missing structure fields.');
end

function value = readJson(path)
value = jsondecode(fileread(path));
end
