function report = verify_stage4_export_integrity()
% Research verification including private pollution fixtures; never an Agent tool.
root = fileparts(fileparts(mfilename('fullpath')));
out = fullfile(root,'results/EXP-20261020-018');
private = fullfile(root,'data/evaluation_private/EXP-20261020-018');
assert(~isfile(fullfile(out,'export_integrity.json')),'Paper:ExistingVerification','Preserve prior checks.');
mapping = jsondecode(fileread(fullfile(private,'case_mapping.json')));
checks = struct('name',{},'passed',{});
policy = jsondecode(fileread(fullfile(root,'configs/observation_export_v1.json')));
release = fullfile(root,'data/agent_visible/observations_boundary_v1');
files = dir(fullfile(release,'**','*')); files = files(~[files.isdir]);
add('exactly_21_public_release_files',numel(files)==21);
for k=1:2
    cid = mapping(k).case_id; prefix = sprintf('case%d_',k);
    folder = fullfile(release,cid);
    raw = load(fullfile(root,'results',mapping(k).source_run_id,'observations_aligned.mat'),'observations');
    saved = load(fullfile(folder,cid,'observations.mat'));
    add([prefix 'only_observation_container'],isequal(fieldnames(saved),{'observations'}));
    add([prefix 'exact_seven_field_whitelist'],isequal(sort(fieldnames(saved.observations)),sort(policy.observation_fields)));
    for j=1:7
        name = policy.observation_fields{j};
        add([prefix 'roundtrip_' name],isequal(saved.observations.(name),raw.observations.(name)));
    end
    parameters = jsondecode(fileread(fullfile(folder,'parameters.json')));
    source = load(fullfile(root,'data/evaluation_private',mapping(k).source_run_id,'generation.mat'),'generation');
    groups = {'motor','mechanics'}; fields = {policy.motor_parameters,policy.mechanical_parameters};
    match = true;
    for g=1:2
        names = fields{g};
        match = match && isequal(sort(fieldnames(parameters.nominal.(groups{g}))),sort(names));
        for j=1:numel(names)
            match = match && parameters.nominal.(groups{g}).(names{j})==source.generation.nominal.(groups{g}).(names{j});
        end
    end
    add([prefix 'eleven_parameters_match_generation'],match);
    context = jsondecode(fileread(fullfile(folder,'operating_context.json')));
    add([prefix 'command_not_independent_measurement'],~context.independent_load_measurement_available && ~context.actual_load_independently_verified);
    [assumedLoad,info] = read_boundary_assumption(folder,fullfile(folder,'manifest.json'));
    add([prefix 'assumption_is_numeric_and_not_measurement'],max(assumedLoad.external_force_N)==1500 && ~info.independent_measurement);
end
% Structural pollution must fail even after recomputing the fixture hashes.
cid = mapping(1).case_id; sourceFolder = fullfile(release,cid);
fixture = fullfile(private,'observation_pollution_fixture'); copyfile(sourceFolder,fixture);
saved = load(fullfile(fixture,cid,'observations.mat'));
observations = saved.observations; observations.config = struct('private_truth',1);
save(fullfile(fixture,cid,'observations.mat'),'observations','-v7');
metaPath = fullfile(fixture,cid,'metadata.json'); meta = jsondecode(fileread(metaPath));
meta.observations_sha256 = paper_file_sha256(fullfile(fixture,cid,'observations.mat')); writeJson(metaPath,meta);
manifestPath = fullfile(fixture,'manifest.json'); manifest = jsondecode(fileread(manifestPath));
for k=1:numel(manifest.files)
    manifest.files(k).sha256 = paper_file_sha256(fullfile(fixture,manifest.files(k).path));
end
writeJson(manifestPath,manifest);
response = inspect_case_core(cid,fixture,manifestPath);
add('truth_field_rejected_after_rehash',strcmp(response.status,'execution_error') && isempty(response.evidence));
fixture = fullfile(private,'assumption_pollution_fixture'); copyfile(sourceFolder,fixture);
infoPath = fullfile(fixture,'diagnostic_assumption.json'); info = jsondecode(fileread(infoPath));
info.independent_measurement = true; writeJson(infoPath,info);
manifestPath = fullfile(fixture,'manifest.json'); manifest = jsondecode(fileread(manifestPath));
idx = strcmp({manifest.files.path},'diagnostic_assumption.json');
manifest.files(idx).sha256 = paper_file_sha256(infoPath); writeJson(manifestPath,manifest);
rejected = false;
try
    read_boundary_assumption(fixture,manifestPath);
catch issue
    rejected = strcmp(issue.identifier,'Residual:invalid_assumption_provenance');
end
add('false_measurement_provenance_rejected_after_rehash',rejected);
% Public JSON and file names must not contain source labels or private paths.
for k=1:numel(files)
    path = fullfile(files(k).folder,files(k).name);
    if endsWith(path,'.json')
        text = fileread(path);
        add(sprintf('public_json_%d_no_case_truth',k),~contains(text,'evaluation_private') && ...
            ~contains(text,'source_run_id') && ~contains(text,'reference_class') && ...
            ~contains(text,'position_bias_m') && ~contains(text,'private_position_true_m') && ...
            isempty(regexp(text,'F[123]|injected_|appliedFault','once')));
    end
end
report = struct('passed',all([checks.passed]),'check_count',numel(checks), ...
    'checks_passed',nnz([checks.passed]),'checks',checks,'public_file_count',numel(files), ...
    'source_observation_fields_roundtrip',14,'new_simulations',0,'llm_calls',0);
writeJson(fullfile(out,'export_integrity.json'),report);
assert(report.passed,'Paper:ExportIntegrity','Export verification failed; preserve evidence.');
fprintf('Export/information-isolation checks %d/%d.\n',report.checks_passed,report.check_count);

    function add(name,condition)
        checks(end+1) = struct('name',name,'passed',logical(condition));
    end
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8');
assert(handle>=0,'Paper:Write','Cannot write verification.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
