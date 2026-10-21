function report = test_inspect_case(reportFolder)
% Research-side acceptance tests; never register this function for Agent use.
root = fileparts(fileparts(mfilename('fullpath')));
release = fullfile(root,'data','agent_visible','observations_v1');
manifestPath = fullfile(root,'tools','registry','observations_v1_manifest.json');
if nargin==0, reportFolder = fullfile(root,'results','EXP-20261019-005'); end
out = char(java.io.File(reportFolder).getCanonicalPath());
resultsBase = char(java.io.File(fullfile(root,'results')).getCanonicalPath());
assert(startsWith(lower(out),lower([resultsBase filesep])), ...
    'Paper:TestOutputRoot','Research test output must stay under project results.');
assert(~isfile(fullfile(out,'acceptance.json')),'Paper:ExistingTestReport', ...
    'Use a new research report folder for another acceptance run.');
private = fullfile(root,'data','evaluation_private','EXP-20261019-005');
if ~isfolder(out), mkdir(out); end
if ~isfolder(private), mkdir(private); end
id = char(java.util.UUID.randomUUID());
fixture = fullfile(private,['fixture_' id]);
[ok,message] = copyfile(release,fixture);
assert(ok,'%s',message);
fixtureManifest = fullfile(private,['manifest_' id '.json']);
catalog = jsondecode(fileread(fullfile(release,'catalog.json')));
checks = struct('name',{},'passed',{},'status',{},'error_code',{});
responses = cell(7,1); readSets = cell(7,1);
for k = 1:7
    caseId = catalog.cases(k).case_id;
    responses{k} = inspect_case(caseId);
    [internal,readSets{k}] = inspect_case_core(caseId,release,manifestPath);
    checks(end+1) = check(['approved_case_' num2str(k)], ...
        strcmp(responses{k}.status,'ok') && internal.result.numeric_input_ready && ...
        numel(readSets{k})==5 && all([internal.result.channels.sample_count]==160001) && ...
        internal.result.phase_sum_interpretation_ready && ...
        ~internal.result.compensated_torque_independently_supported && ...
        ~internal.result.position_absolute_reference_available && ...
        isempty(internal.model_hash),responses{k}); %#ok<AGROW>
    assertSafe(responses{k});
end
caseId = catalog.cases(1).case_id;
repeat = inspect_case(caseId);
checks(end+1) = check('stable_evidence_for_same_inputs', ...
    isequal(rmfield(repeat,'duration_ms'),rmfield(responses{1},'duration_ms')),repeat);
bad = inspect_case('../data/evaluation_private/hidden.mat');
checks(end+1) = expected('path_id_rejected',bad,'execution_error','invalid_case_id');
assert(isempty(bad.case_id)); assertSafe(bad);
bad = ema_tool('inspect_case',struct('case_id',caseId,'path','private'));
checks(end+1) = expected('extra_argument_rejected',bad,'execution_error','invalid_arguments');
bad = ema_tool('paper_run_f1_severity_1500N',struct('case_id',caseId));
checks(end+1) = expected('unregistered_function_rejected',bad,'execution_error','unsupported_tool_or_call');
bad = inspect_case(42);
checks(end+1) = expected('non_string_id_rejected',bad,'execution_error','invalid_arguments');
bad = inspect_case('CASE-00000000000000000000000000000000');
checks(end+1) = expected('unknown_case_reported',bad,'insufficient_data','case_not_found');
scenarios = {'missing_channel','nonfinite','wrong_width','bad_time','wrong_sample_time', ...
    'wrong_unit','reconstructed_phase','missing_file','unapproved_change','corrupt_mat', ...
    'extra_truth_field','metadata_label_text','catalog_path_injection'};
for k = 1:numel(scenarios)
    touched = {'catalog.json','channel_contract.json','operating_context.json', ...
        [caseId '/metadata.json'],[caseId '/observations.mat']};
    for j = 1:numel(touched)
        copyfile(fullfile(release,touched{j}),fullfile(fixture,touched{j}),'f');
    end
    matFile = fullfile(fixture,caseId,'observations.mat');
    metaFile = fullfile(fixture,caseId,'metadata.json');
    saved = load(matFile); observations = saved.observations;
    meta = jsondecode(fileread(metaFile));
    scenario = scenarios{k};
    desiredStatus = 'execution_error'; desiredError = '';
    reseal = true;
    switch scenario
        case 'missing_channel'
            observations = rmfield(observations,'iq_meas_A');
            desiredStatus = 'insufficient_data'; desiredError = 'missing_or_invalid_channel_data';
        case 'nonfinite'
            observations.x_meas_m(3) = NaN;
            desiredStatus = 'insufficient_data'; desiredError = 'missing_or_invalid_channel_data';
        case 'wrong_width'
            observations.iabc_meas_A = observations.iabc_meas_A(:,1:2);
            desiredStatus = 'not_applicable'; desiredError = 'unsupported_sampling_units_or_width';
        case 'bad_time'
            observations.time_s(3) = observations.time_s(2);
            desiredStatus = 'insufficient_data'; desiredError = 'missing_or_invalid_channel_data';
        case 'wrong_sample_time'
            observations.time_s = observations.time_s*2;
            meta.time_range_s = [0,1.6];
            desiredStatus = 'not_applicable'; desiredError = 'unsupported_sampling_units_or_width';
        case 'wrong_unit'
            c = jsondecode(fileread(fullfile(fixture,'channel_contract.json')));
            c.channels(2).unit = 'mm';
            writeJson(fullfile(fixture,'channel_contract.json'),c);
            desiredStatus = 'not_applicable'; desiredError = 'unsupported_sampling_units_or_width';
        case 'reconstructed_phase'
            c = jsondecode(fileread(fullfile(fixture,'channel_contract.json')));
            c.phase_acquisition = 'third_phase_reconstructed';
            writeJson(fullfile(fixture,'channel_contract.json'),c);
            desiredStatus = 'ok';
        case 'missing_file'
            delete(matFile);
            desiredStatus = 'insufficient_data'; desiredError = 'missing_artifact';
            reseal = false;
        case 'unapproved_change'
            observations.x_meas_m(3) = observations.x_meas_m(3)+1;
            reseal = false; desiredError = 'integrity_mismatch';
        case 'corrupt_mat'
            desiredError = 'internal_execution_error';
        case 'extra_truth_field'
            observations.injected_secret = 1;
            desiredError = 'unapproved_data_structure';
        case 'metadata_label_text'
            c = jsondecode(fileread(fullfile(fixture,'operating_context.json')));
            c.limitation = 'F1 EXP-20261016-001 C:\secret\hidden.mat';
            writeJson(fullfile(fixture,'operating_context.json'),c);
            desiredStatus = 'ok';
        case 'catalog_path_injection'
            c = jsondecode(fileread(fullfile(fixture,'catalog.json')));
            c.cases(1).source_path = '../evaluation_private/secret.mat';
            writeJson(fullfile(fixture,'catalog.json'),c);
            desiredError = 'invalid_catalog';
    end
    if ~strcmp(scenario,'missing_file')
        save(matFile,'observations','-v7');
        if strcmp(scenario,'corrupt_mat')
            handle = fopen(matFile,'w'); fprintf(handle,'not a MAT file'); fclose(handle);
        end
        if reseal
            meta.observations_sha256 = sha(matFile);
            writeJson(metaFile,meta);
        end
    end
    sealed = jsondecode(fileread(manifestPath));
    if reseal
        for j = 1:numel(sealed.files)
            sealed.files(j).sha256 = sha(fullfile(fixture,sealed.files(j).path));
        end
    end
    writeJson(fixtureManifest,sealed);
    [value,reads] = inspect_case_core(caseId,fixture,fixtureManifest);
    passed = strcmp(value.status,desiredStatus) && strcmp(value.error_code,desiredError);
    if strcmp(scenario,'reconstructed_phase')
        passed = passed && ~value.result.phase_sum_interpretation_ready && ...
            strcmp(value.preconditions(2).state,'violated');
    elseif strcmp(scenario,'missing_channel')
        passed = passed && ~value.result.channels(6).present && value.result.channels(2).present;
    elseif strcmp(scenario,'wrong_unit')
        passed = passed && strcmp(value.result.channels(2).unit,'mm') && ...
            ~value.result.channels(2).unit_matches_contract;
    elseif strcmp(scenario,'catalog_path_injection')
        passed = passed && isscalar(reads);
    end
    assertSafe(value);
    checks(end+1) = check(scenario,passed,value); %#ok<AGROW>
end
files = {'ema_tool.m','inspect_case.m','private/inspect_case_core.m','test_inspect_case.m'};
lint = struct('file',{},'message_count',{},'messages',{});
for k = 1:numel(files)
    issues = checkcode(fullfile(root,'tools',files{k}),'-id');
    lint(end+1) = struct('file',files{k},'message_count',numel(issues),'messages',issues); %#ok<AGROW>
end
report = struct('experiment_id','EXP-20261019-005','user_stage',2, ...
    'step',3,'substep','inspect_case','tool_version','EMA-INSPECT-1.0', ...
    'case_count',7,'new_physical_runs',0,'llm_agent_calls',0, ...
    'passed',all([checks.passed]) && all([lint.message_count]==0), ...
    'checks',checks,'code_analyzer',lint,'approved_read_sets',{readSets}, ...
    'completed_at',char(datetime('now','TimeZone','Asia/Shanghai')));
writeJson(fullfile(out,'acceptance.json'),report);
writeJson(fullfile(out,'case_responses.json'),responses);
assert(report.passed,'Paper:InspectTests','Inspect acceptance failed; see research-side report.');
fprintf('inspect_case: %d/%d checks passed; seven actual-case responses saved.\n', ...
    nnz([checks.passed]),numel(checks));
end

function value = check(name,passed,response)
value = struct('name',name,'passed',passed,'status',response.status,'error_code',response.error_code);
end

function value = expected(name,response,status,errorCode)
assertSafe(response);
value = check(name,strcmp(response.status,status) && strcmp(response.error_code,errorCode),response);
end

function assertSafe(value)
text = jsonencode(value);
blocked = '(?i)(EXP-\d{8}|(?<![a-z0-9])F[123](?![a-z0-9])|healthy|gradual|injected_|evaluation_private|legacy_private|[a-z]:[\\/]|secret)';
assert(isempty(regexp(text,blocked,'once')),'Paper:InspectLeak','Tool response leaked restricted text.');
end

function value = sha(path)
handle = fopen(path,'rb'); assert(handle>=0);
cleanup = onCleanup(@() fclose(handle));
digest = java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(fread(handle,Inf,'*uint8'),'int8'));
value = lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8'); assert(handle>=0);
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
