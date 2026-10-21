function report = test_compute_residual_bundle(reportFolder)
% Research acceptance only. References and fixtures must not be Agent tools.
root = fileparts(fileparts(mfilename('fullpath')));
release = fullfile(root,'data','agent_visible','observations_v1');
manifestPath = fullfile(root,'tools','registry','observations_v1_manifest.json');
algorithm = fullfile(root,'tools','registry','residual_algorithm_v1.json');
derived = fullfile(root,'data','agent_visible','derived_v1');
if nargin==0, reportFolder = fullfile(root,'results','EXP-20261019-006'); end
out = char(java.io.File(reportFolder).getCanonicalPath());
resultsBase = char(java.io.File(fullfile(root,'results')).getCanonicalPath());
require(startsWith(lower(out),lower([resultsBase filesep])),'test_output_root');
require(~isfile(fullfile(out,'acceptance.json')),'existing_test_report');
private = fullfile(root,'data','evaluation_private','EXP-20261019-006');
if ~isfolder(out), mkdir(out); end
if ~isfolder(private), mkdir(private); end
mapping = jsondecode(fileread(fullfile(root,'data','evaluation_private', ...
    'EXP-20261019-004','case_mapping.json')));
checks = struct('name',{},'passed',{},'status',{},'error_code',{});
comparisons = struct('case_id',{},'source_run_id',{},'quantity',{}, ...
    'max_absolute_difference',{},'tolerance',{},'passed',{});
responses = cell(7,2);
for k = 1:numel(mapping)
    caseId = mapping(k).case_id;
    responses{k,1} = compute_residual_bundle(caseId);
    responses{k,2} = compute_residual_bundle(caseId,'prescribed_command');
    plain = responses{k,1}; compensated = responses{k,2};
    assertSafe(plain); assertSafe(compensated);
    require(strcmp(plain.status,'ok') && strcmp(compensated.status,'ok'),'actual_case_failed');
    r0 = loadBundle(plain,derived); r1 = loadBundle(compensated,derived);
    reference = load(fullfile(root,'results',mapping(k).source_run_id,'residuals.mat'),'residuals');
    names = fieldnames(reference.residuals);
    allPassed = true;
    for j = 1:numel(names)
        field = names{j};
        a = r1.(field); b = reference.residuals.(field);
        difference = max(abs(double(a(:))-double(b(:))));
        tolerance = 0;
        if strcmp(field,'torque_known_load_Nm'), tolerance = 1e-8; end
        passed = isequal(size(a),size(b)) && difference<=tolerance;
        comparisons(end+1) = struct('case_id',caseId,'source_run_id',mapping(k).source_run_id, ...
            'quantity',field,'max_absolute_difference',difference,'tolerance',tolerance, ...
            'passed',passed); %#ok<AGROW>
        allPassed = allPassed && passed;
    end
    checks(end+1) = check(['reference_arrays_' num2str(k)],allPassed,compensated); %#ok<AGROW>
    checks(end+1) = check(['no_implicit_compensation_' num2str(k)], ...
        ~isfield(r0,'torque_known_load_Nm') && plain.result.partial_result && ...
        strcmp(plain.result.channels(4).status,'insufficient_data') && ...
        ~plain.result.compensation_available,plain); %#ok<AGROW>
    checks(end+1) = check(['time_mask_and_finiteness_' num2str(k)], ...
        isequal(r0.time_s,r1.time_s) && isequal(r0.motion_valid,r1.motion_valid) && ...
        isequal(r0.x_consistency_m,r1.x_consistency_m) && ...
        isequal(r0.phase_sum_A,r1.phase_sum_A) && finiteBundle(r0) && finiteBundle(r1) && ...
        compensated.result.output_sample_count==791 && compensated.result.motion_valid_samples==408,compensated); %#ok<AGROW>
    checks(end+1) = check(['assumption_not_independent_evidence_' num2str(k)], ...
        compensated.result.compensation_available && ~compensated.result.independent_load_supported && ...
        strcmp(compensated.preconditions(3).state,'unknown') && ...
        ismember('COMPENSATION_IS_COMMAND_ASSUMPTION',compensated.warnings),compensated); %#ok<AGROW>
end
caseId = mapping(1).case_id;
repeat = compute_residual_bundle(caseId);
checks(end+1) = check('same_input_reuses_unchanged_artifact', ...
    strcmp(repeat.input_hash,responses{1,1}.input_hash) && repeat.result.artifact_reused && ...
    strcmp(repeat.result.artifact_sha256,responses{1,1}.result.artifact_sha256),repeat);
checks(end+1) = check('load_modes_have_distinct_evidence', ...
    ~strcmp(responses{1,1}.result.bundle_id,responses{1,2}.result.bundle_id),responses{1,2});
bad = compute_residual_bundle(caseId,'actual_hidden_load');
checks(end+1) = expected('unsupported_load_mode_rejected',bad,'execution_error','invalid_load_assumption');
bad = ema_tool('compute_residual_bundle',struct('case_id',caseId,'path','private'));
checks(end+1) = expected('path_argument_rejected',bad,'execution_error','invalid_arguments');
bad = compute_residual_bundle('../private/secret.mat');
checks(end+1) = expected('path_id_rejected',bad,'execution_error','invalid_case_id');
bad = compute_residual_bundle('CASE-00000000000000000000000000000000');
checks(end+1) = expected('unknown_case_reported',bad,'insufficient_data','case_not_found');
fixedText = fileread(fullfile(root,'matlab','fixed','paper_ema_diagnostic_residuals.m'));
gradualText = fileread(fullfile(root,'matlab','gradual','paper_ema_diagnostic_residuals.m'));
copied = fileread(fullfile(root,'tools','private','residual_kernel_v1.m'));
copied = strrep(copied,'function r = residual_kernel_v1(d, nominal)', ...
    'function r = paper_ema_diagnostic_residuals(d, nominal)');
checks(end+1) = check('kernel_body_matches_both_sources', ...
    strcmp(fixedText,gradualText) && strcmp(fixedText,copied),responses{1,1});
id = char(java.util.UUID.randomUUID());
fixture = fullfile(private,['fixture_' id]);
[ok,message] = copyfile(release,fixture); assert(ok,'%s',message);
fixtureManifest = fullfile(private,['manifest_' id '.json']);
scenarioNames = {'missing_channel','wrong_sample_time','reconstructed_phase', ...
    'missing_command_default','missing_command_selected','nonfinite_command', ...
    'invalid_parameters','unapproved_parameters','extra_parameter_truth', ...
    'no_valid_motion','short_input','corrupt_algorithm_registry','corrupt_evidence'};
for k = 1:numel(scenarioNames)
    touched = {'parameters.json','channel_contract.json','operating_context.mat', ...
        [caseId '/observations.mat'],[caseId '/metadata.json']};
    for j = 1:numel(touched)
        copyfile(fullfile(release,touched{j}),fullfile(fixture,touched{j}),'f');
    end
    matFile = fullfile(fixture,caseId,'observations.mat');
    metaFile = fullfile(fixture,caseId,'metadata.json');
    loaded = load(matFile); observations = loaded.observations;
    meta = jsondecode(fileread(metaFile));
    desiredStatus = 'execution_error'; desiredError = ''; mode = 'none';
    reseal = true; selectedAlgorithm = algorithm;
    scenario = scenarioNames{k};
    switch scenario
        case 'missing_channel'
            observations = rmfield(observations,'iq_meas_A');
            desiredStatus = 'insufficient_data'; desiredError = 'missing_or_invalid_channel_data';
        case 'wrong_sample_time'
            observations.time_s = 2*observations.time_s;
            meta.time_range_s = [0,1.6];
            desiredStatus = 'not_applicable'; desiredError = 'unsupported_sampling_units_or_width';
        case 'reconstructed_phase'
            c = jsondecode(fileread(fullfile(fixture,'channel_contract.json')));
            c.phase_acquisition = 'third_phase_reconstructed';
            writeJson(fullfile(fixture,'channel_contract.json'),c); desiredStatus = 'ok';
        case {'missing_command_default','missing_command_selected'}
            delete(fullfile(fixture,'operating_context.mat')); desiredStatus = 'ok';
            if strcmp(scenario,'missing_command_selected'), mode = 'prescribed_command'; end
        case 'nonfinite_command'
            c = load(fullfile(fixture,'operating_context.mat')); command = c.command;
            command.compensation_force_N(3) = NaN;
            save(fullfile(fixture,'operating_context.mat'),'command','-v7');
            mode = 'prescribed_command'; desiredStatus = 'ok';
        case {'invalid_parameters','unapproved_parameters','extra_parameter_truth'}
            p = jsondecode(fileread(fullfile(fixture,'parameters.json')));
            if strcmp(scenario,'extra_parameter_truth')
                p.nominal.fault = 'secret'; desiredError = 'invalid_parameters';
            elseif strcmp(scenario,'invalid_parameters')
                p.nominal.mechanics.efficiency = 0; desiredError = 'invalid_parameters';
            else
                p.nominal.mechanics.efficiency = 0.5;
                reseal = false; desiredError = 'integrity_mismatch';
            end
            writeJson(fullfile(fixture,'parameters.json'),p);
        case 'no_valid_motion'
            observations.omega_meas_radps(:) = 0;
            desiredStatus = 'insufficient_data'; desiredError = 'no_valid_motion_window';
        case 'short_input'
            names = fieldnames(observations);
            for j = 1:numel(names), observations.(names{j}) = observations.(names{j})(1:1000,:); end
            meta.sample_count = 1000; meta.time_range_s = [0,observations.time_s(end)];
            desiredStatus = 'insufficient_data'; desiredError = 'insufficient_window_length';
        case 'corrupt_algorithm_registry'
            descriptor = jsondecode(fileread(algorithm)); descriptor.kernel_sha256 = repmat('0',1,64);
            selectedAlgorithm = fullfile(private,['algorithm_' id '.json']);
            writeJson(selectedAlgorithm,descriptor); desiredError = 'algorithm_integrity_mismatch';
        case 'corrupt_evidence'
            desiredError = 'evidence_integrity_mismatch';
    end
    save(matFile,'observations','-v7');
    meta.observations_sha256 = tool_sha256(matFile,'file'); writeJson(metaFile,meta);
    sealed = jsondecode(fileread(manifestPath));
    if reseal
        for j = 1:numel(sealed.files)
            file = fullfile(fixture,sealed.files(j).path);
            if isfile(file), sealed.files(j).sha256 = tool_sha256(file,'file'); end
        end
    else
        % Keep the original parameter signature; approve only fixture observations/metadata.
        for j = 1:numel(sealed.files)
            if ismember(sealed.files(j).path,{[caseId '/observations.mat'],[caseId '/metadata.json']})
                sealed.files(j).sha256 = tool_sha256(fullfile(fixture,sealed.files(j).path),'file');
            end
        end
    end
    writeJson(fixtureManifest,sealed);
    evidenceRoot = fullfile(private,['evidence_' id '_' num2str(k)]);
    if strcmp(scenario,'corrupt_evidence')
        first = compute_residual_core(caseId,mode,fixture,fixtureManifest,evidenceRoot,selectedAlgorithm);
        require(strcmp(first.status,'ok'),'evidence_fixture_failed');
        path = fullfile(evidenceRoot,first.result.bundle_id,'residuals.mat');
        s = load(path); residuals = s.residuals; residuals.x_consistency_m(1) = 1;
        save(path,'residuals','-v7');
    end
    value = compute_residual_core(caseId,mode,fixture,fixtureManifest,evidenceRoot,selectedAlgorithm);
    passed = strcmp(value.status,desiredStatus) && strcmp(value.error_code,desiredError);
    if strcmp(scenario,'reconstructed_phase') && passed
        r = loadBundle(value,evidenceRoot);
        passed = ~isfield(r,'phase_sum_A') && strcmp(value.result.channels(2).status,'not_applicable');
    elseif ismember(scenario,{'missing_command_default','missing_command_selected','nonfinite_command'}) && passed
        r = loadBundle(value,evidenceRoot);
        passed = ~isfield(r,'torque_known_load_Nm') && finiteBundle(r) && ...
            strcmp(value.result.channels(1).status,'ok');
    elseif strcmp(scenario,'no_valid_motion') && passed
        passed = value.result.motion_valid_samples==0 && ...
            strcmp(value.preconditions(5).state,'violated') && finiteBundle(loadBundle(value,evidenceRoot));
    end
    assertSafe(value);
    checks(end+1) = check(scenario,passed,value); %#ok<AGROW>
end
files = {'ema_tool.m','compute_residual_bundle.m','private/compute_residual_core.m', ...
    'private/read_residual_input.m','private/tool_sha256.m','private/residual_kernel_v1.m', ...
    'private/inspect_case_core.m','test_compute_residual_bundle.m'};
lint = struct('file',{},'message_count',{},'messages',{});
for k = 1:numel(files)
    issues = checkcode(fullfile(root,'tools',files{k}),'-id');
    lint(end+1) = struct('file',files{k},'message_count',numel(issues),'messages',issues); %#ok<AGROW>
end
report = struct('experiment_id','EXP-20261019-006','stage',2,'step',3, ...
    'substep',2,'tool_version','EMA-RESIDUAL-1.0','passed', ...
    all([checks.passed]) && all([comparisons.passed]) && all([lint.message_count]==0), ...
    'case_count',7,'load_modes',{{'none','prescribed_command'}}, ...
    'new_physical_runs',0,'llm_agent_calls',0,'checks',checks, ...
    'numerical_comparisons',comparisons,'code_analyzer',lint, ...
    'completed_at',char(datetime('now','TimeZone','Asia/Shanghai')));
writeJson(fullfile(out,'acceptance.json'),report);
writeJson(fullfile(out,'case_responses.json'),responses);
writetable(struct2table(comparisons),fullfile(out,'numerical_comparison.csv'),'Encoding','UTF-8');
require(report.passed,'acceptance_failed');
fprintf('Residual tool: %d/%d checks and %d/%d reference-array comparisons passed.\n', ...
    nnz([checks.passed]),numel(checks),nnz([comparisons.passed]),numel(comparisons));
end

function r = loadBundle(response,root)
require(isfield(response.result,'bundle_id'),'missing_bundle');
s = load(fullfile(root,response.result.bundle_id,'residuals.mat'),'residuals'); r = s.residuals;
end

function yes = finiteBundle(r)
yes = all(structfun(@(v) all(isfinite(v(:))),r));
end

function value = check(name,passed,response)
value = struct('name',name,'passed',passed,'status',response.status,'error_code',response.error_code);
end

function value = expected(name,response,status,errorCode)
assertSafe(response);
value = check(name,strcmp(response.status,status) && strcmp(response.error_code,errorCode),response);
end

function assertSafe(value)
blocked = '(?i)(EXP-\d{8}|(?<![a-z0-9])F[123](?![a-z0-9])|healthy|gradual|injected_|evaluation_private|legacy_private|(?<![a-z])[a-z]:[\\/]|secret)';
require(isempty(regexp(jsonencode(value),blocked,'once')),'response_leak');
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8'); assert(handle>=0);
cleanup = onCleanup(@() fclose(handle)); fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end

function require(yes,code)
assert(isscalar(yes) && yes,['ResidualTest:' code],'Residual acceptance failed.');
end
