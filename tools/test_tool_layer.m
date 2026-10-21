function report = test_tool_layer(reportFolder)
% Research-only end-to-end acceptance. This predetermined sequence is not an Agent.
root = fileparts(fileparts(mfilename('fullpath')));
if nargin==0, reportFolder = fullfile(root,'results','EXP-20261019-010'); end
out = char(java.io.File(reportFolder).getCanonicalPath());
base = char(java.io.File(fullfile(root,'results')).getCanonicalPath());
assert(startsWith(lower(out),lower([base filesep])) && ...
    ~isfile(fullfile(out,'acceptance.json')),'LayerTest:new_report_required','Use a new report folder.');
if ~isfolder(out), mkdir(out); end
registryFolder = fullfile(root,'tools','registry');
registry = jsondecode(fileread(fullfile(registryFolder,'tool_registry_v1.json')));
release = fullfile(root,'data','agent_visible','observations_v1');
manifest = fullfile(registryFolder,'observations_v1_manifest.json');
catalog = jsondecode(fileread(fullfile(release,'catalog.json')));
before = protectedHashes(root);
writeJson(fullfile(out,'protected_hashes_before.json'),before);
checks = struct('name',{},'passed',{});
traces = cell(7,1); summaries = struct([]); evidenceIndex = struct([]);
names = {'inspect_case','compute_residual_bundle','locate_anomalies', ...
    'query_operating_context','lookup_method_conditions','plot_evidence'};
statuses = {'ok','not_applicable','insufficient_data','execution_error'};
add('exactly_six_registered_tools',strcmp(registry.registry_version,'EMA-TOOLS-1.0') && ...
    strcmp(registry.entrypoint,'ema_tool') && ...
    isequal({registry.tools.name},names) && ~registry.llm_connected && ...
    ~registry.allows_arbitrary_matlab && ~registry.process_sandbox);
for k = 1:6
    definition = registry.tools(k);
    path = fullfile(registryFolder,definition.schema_file);
    schema = jsondecode(fileread(path));
    add(['schema_contract_' names{k}],strcmp(definition.schema_sha256,tool_sha256(path,'file')) && ...
        strcmp(schema.name,names{k}) && strcmp(schema.version,definition.version) && ...
        ischar(schema.description) && ~schema.parameters.additionalProperties && ...
        ~schema.allows_path_arguments && ~schema.returns_raw_waveforms && ...
        isequal(cellstr(schema.statuses),statuses(:)));
end
for k = 1:7
    caseId = catalog.cases(k).case_id; trace = struct([]);
    inspection = invoke('inspect_case',struct('case_id',caseId));
    context = invoke('query_operating_context',struct('case_id',caseId));
    methods = invoke('lookup_method_conditions',struct('method_id','all','case_id',caseId));
    plain = invoke('compute_residual_bundle',struct('case_id',caseId));
    plainAlarms = invoke('locate_anomalies',struct('residual_evidence_id',plain.result.bundle_id));
    compensated = invoke('compute_residual_bundle',struct('case_id',caseId, ...
        'load_assumption','prescribed_command'));
    alarms = invoke('locate_anomalies',struct('residual_evidence_id',compensated.result.bundle_id));
    figureReply = invoke('plot_evidence',struct('residual_evidence_id',compensated.result.bundle_id));
    traces{k} = trace;
    values = {inspection,context,methods,plain,plainAlarms,compensated,alarms,figureReply};
    add(['all_six_tools_in_actual_chain_' num2str(k)],all(cellfun(@(v) ...
        strcmp(v.status,'ok') && strcmp(v.case_id,caseId) && commonContract(v,registry),values)));
    add(['inspection_to_residual_reference_' num2str(k)], ...
        strcmp(plain.result.input_inspection_evidence_id,inspection.evidence.id) && ...
        strcmp(compensated.result.input_inspection_evidence_id,inspection.evidence.id) && ...
        plain.result.output_sample_count==791 && compensated.result.motion_valid_samples==408);
    add(['default_compensation_not_invented_' num2str(k)],plain.result.partial_result && ...
        ~plain.result.compensation_available && plainAlarms.result.partial_result && ...
        plainAlarms.result.detector_call_count==2 && ...
        strcmp(plainAlarms.result.channels(3).status,'insufficient_data') && ...
        isempty(plainAlarms.result.channels(3).alarmed) && ...
        ~plainAlarms.result.channels(3).detector_executed);
    add(['command_assumption_explicit_and_not_independent_' num2str(k)], ...
        strcmp(compensated.result.load_assumption,'prescribed_command') && ...
        compensated.result.compensation_available && ~compensated.result.independent_load_supported && ...
        ismember('COMPENSATION_IS_COMMAND_ASSUMPTION',compensated.warnings) && ...
        ~strcmp(plain.result.bundle_id,compensated.result.bundle_id) && ...
        strcmp(precondition(compensated,'independent_normal_load'),'unknown') && ...
        strcmp(precondition(alarms,'independent_normal_load'),'unknown') && ...
        strcmp(precondition(figureReply,'independent_normal_load'),'unknown'));
    missing = context.result.records(ismember({context.result.records.name},{'independent_load','initial_reference'}));
    add(['conditions_not_promoted_to_certainty_' num2str(k)],numel(missing)==2 && ...
        all(strcmp({missing.status},'insufficient_data')) && ...
        all(arrayfun(@(v) ~v.value.available,missing)) && ~methods.result.contains_case_diagnosis && ...
        strcmp(precondition(methods,'independent_initial_reference'),'unknown') && ...
        strcmp(precondition(methods,'independent_normal_load'),'unknown') && ...
        strcmp(precondition(figureReply,'independent_initial_reference'),'unknown'));
    linked = strcmp(alarms.result.residual_evidence_id,compensated.result.bundle_id) && ...
        strcmp(figureReply.result.residual_evidence_id,compensated.result.bundle_id) && ...
        strcmp(figureReply.evidence.parent_evidence_id,compensated.result.bundle_id);
    for j = 1:3
        channel = alarms.result.channels(j);
        source = compensated.result.channels(strcmp({compensated.result.channels.quantity},channel.quantity));
        linked = linked && channel.detector_executed && strcmp(channel.parent_evidence_id,source.evidence_id);
    end
    add(['residual_alarm_figure_chain_references_' num2str(k)],linked);
    folder = fullfile(root,'data','agent_visible','figures_v1',figureReply.result.plot_id);
    meta = jsondecode(fileread(fullfile(folder,'metadata.json')));
    add(['figure_source_and_files_verified_' num2str(k)], ...
        strcmp(meta.case_id,caseId) && strcmp(meta.residual_evidence_id,compensated.result.bundle_id) && ...
        strcmp(meta.anomaly_input_hash,alarms.input_hash) && ...
        strcmp(meta.residual_artifact_sha256,compensated.result.artifact_sha256) && ...
        strcmp(tool_sha256(fullfile(folder,'overview.png'),'file'),figureReply.result.png_sha256) && ...
        strcmp(tool_sha256(fullfile(folder,'overview.fig'),'file'),figureReply.result.fig_sha256));
    add(['all_chain_responses_no_private_data_' num2str(k)],all(cellfun(@safeResponse,values)));
    summaries = [summaries;struct('case_id',caseId,'group_id',inspection.result.group_id, ...
        'tool_calls',numel(trace),'compensated_bundle_id',compensated.result.bundle_id, ...
        'uncompensated_bundle_id',plain.result.bundle_id,'plot_id',figureReply.result.plot_id, ...
        'alarmed_channels',{{alarms.result.channels([alarms.result.channels.alarmed]).quantity}}, ...
        'diagnosis_generated',false,'independent_load_state','unknown', ...
        'initial_reference_state','unknown')]; %#ok<AGROW>
    for j = 1:numel(values)
        evidence = values{j}.evidence;
        for n = 1:numel(evidence)
            parentId = '';
            if isfield(evidence(n),'parent_evidence_id'), parentId = evidence(n).parent_evidence_id; end
            evidenceIndex = [evidenceIndex;struct('id',evidence(n).id,'tool',values{j}.tool, ...
                'case_id',caseId,'quantity',evidence(n).quantity,'parent_evidence_id',parentId)]; %#ok<AGROW>
        end
    end
end
% Public error handling: no recovery via arbitrary filenames or MATLAB calls.
payloads = {struct('case_id',catalog.cases(1).case_id), ...
    struct('case_id',catalog.cases(1).case_id), ...
    struct('residual_evidence_id',traces{1}(6).response.result.bundle_id), ...
    struct('case_id',catalog.cases(1).case_id),struct('method_id','all'), ...
    struct('residual_evidence_id',traces{1}(6).response.result.bundle_id)};
errors = cell(6,1);
for k = 1:6
    payload = payloads{k}; payload.path = '../not_allowed';
    errors{k} = ema_tool(names{k},payload);
    add(['extra_path_rejected_' names{k}],strcmp(errors{k}.status,'execution_error') && ...
        strcmp(errors{k}.error_code,'invalid_arguments') && commonContract(errors{k},registry) && ...
        safeResponse(errors{k}) && isempty(errors{k}.evidence));
end
unknown = ema_tool('paper_run_f1_severity_1500N',struct());
research = ema_tool('test_tool_layer',struct());
future = ema_tool('simulate_hypothesis',struct());
add('generation_research_and_unimplemented_tools_not_registered', ...
    all(cellfun(@(v) strcmp(v.error_code,'unsupported_tool_or_call') && isempty(v.tool) && ...
    isempty(v.tool_version) && isempty(v.evidence) && safeResponse(v),{unknown,research,future})));
unknownCase = ema_tool('inspect_case',struct('case_id',['CASE-' repmat('0',1,32)]));
unknownBundle = ema_tool('locate_anomalies',struct('residual_evidence_id',['BUNDLE-' repmat('0',1,64)]));
add('unavailable_case_and_bundle_are_insufficient_not_no_alarm', ...
    strcmp(unknownCase.status,'insufficient_data') && strcmp(unknownBundle.status,'insufficient_data') && ...
    isempty(unknownCase.evidence) && isempty(unknownBundle.evidence));
short = ema_tool('locate_anomalies',struct('residual_evidence_id',traces{1}(6).response.result.bundle_id, ...
    'analysis_interval_s',[0.04 0.045]));
add('short_interval_no_false_no_alarm',strcmp(short.status,'insufficient_data') && ...
    short.result.detector_call_count==0 && isempty(short.result.any_alarm) && ...
    all(arrayfun(@(v) isempty(v.alarmed),short.result.channels)));
% Isolated researcher-approved fixtures demonstrate status propagation only.
fixture = fullfile(out,'status_fixture'); mkdir(fixture);
shared = {'catalog.json','parameters.json','channel_contract.json','operating_context.json','operating_context.mat'};
for k = 1:numel(shared), copyfile(fullfile(release,shared{k}),fullfile(fixture,shared{k})); end
caseId = catalog.cases(1).case_id;
copyfile(fullfile(release,caseId),fullfile(fixture,caseId));
contract = jsondecode(fileread(fullfile(fixture,'channel_contract.json')));
contract.channels(2).unit = 'mm'; writeJson(fullfile(fixture,'channel_contract.json'),contract);
fixtureManifest = fullfile(out,'fixture_manifest.json'); reseal(fixture,manifest,fixtureManifest);
wrongUnits = inspect_case_core(caseId,fixture,fixtureManifest);
stopped = compute_residual_core(caseId,'none',fixture,fixtureManifest, ...
    fullfile(out,'no_result_expected'),fullfile(registryFolder,'residual_algorithm_v1.json'));
add('not_applicable_propagates_and_creates_no_bundle',strcmp(wrongUnits.status,'not_applicable') && ...
    strcmp(stopped.status,'not_applicable') && ~isfield(stopped.result,'bundle_id') && ...
    ~isfolder(fullfile(out,'no_result_expected')));
copyfile(fullfile(release,'channel_contract.json'),fullfile(fixture,'channel_contract.json'));
loaded = load(fullfile(fixture,caseId,'observations.mat'),'observations');
observations = rmfield(loaded.observations,'iq_meas_A');
save(fullfile(fixture,caseId,'observations.mat'),'observations','-v7.3');
metaPath = fullfile(fixture,caseId,'metadata.json');
metadata = jsondecode(fileread(metaPath));
metadata.observations_sha256 = tool_sha256(fullfile(fixture,caseId,'observations.mat'),'file');
writeJson(metaPath,metadata); reseal(fixture,manifest,fixtureManifest);
missingInput = inspect_case_core(caseId,fixture,fixtureManifest);
stoppedMissing = compute_residual_core(caseId,'none',fixture,fixtureManifest, ...
    fullfile(out,'no_result_expected'),fullfile(registryFolder,'residual_algorithm_v1.json'));
add('missing_channel_propagates_and_creates_no_bundle',strcmp(missingInput.status,'insufficient_data') && ...
    strcmp(stoppedMissing.status,'insufficient_data') && ~isfield(stoppedMissing.result,'bundle_id') && ...
    ~isfolder(fullfile(out,'no_result_expected')));
add('all_four_statuses_observed',isequal(sort(unique({inspection.status,short.status,wrongUnits.status,unknown.status})), ...
    sort(statuses)));
rules = jsondecode(fileread(fullfile(registryFolder,'method_conditions_v1.json')));
add('frozen_generic_rules_and_registry_have_no_case_answers', ...
    strcmp(rules.scope,'generic_physical_conditions_no_case_answers') && ...
    isempty(regexp(jsonencode(rules),'CASE-|RUN-|EXP-|evaluation_private|injected_','once')) && ...
    isempty(regexp(jsonencode(registry),'CASE-|RUN-|EXP-|evaluation_private|injected_','once')));
priorPaths = {'results/EXP-20261019-005/acceptance.json', ...
    'results/EXP-20261019-006/acceptance.json', ...
    'results/EXP-20261019-007/final/acceptance.json', ...
    'results/EXP-20261019-008/final/acceptance.json', ...
    'results/EXP-20261019-009/final/acceptance.json'};
priorReports = struct([]);
for k = 1:numel(priorPaths)
    value = jsondecode(fileread(fullfile(root,priorPaths{k})));
    priorReports = [priorReports;struct('path',priorPaths{k},'passed',value.passed, ...
        'checks_passed',nnz([value.checks.passed]), ...
        'sha256',tool_sha256(fullfile(root,priorPaths{k}),'file'))]; %#ok<AGROW>
end
add('prior_numeric_graphics_and_boundary_acceptances_retained',all([priorReports.passed]));
after = protectedHashes(root);
add('all_approved_sources_residuals_models_and_plots_unchanged',isequal(before,after));
writeJson(fullfile(out,'protected_hashes_after.json'),after);
writeJson(fullfile(out,'tool_call_traces.json'),traces);
writeJson(fullfile(out,'case_chain_summary.json'),summaries);
writeJson(fullfile(out,'evidence_index.json'),evidenceIndex);
writeJson(fullfile(out,'prior_acceptance_index.json'),priorReports);
writeJson(fullfile(out,'status_responses.json'),struct('invalid_inputs',{errors}, ...
    'unknown_tool',unknown,'unknown_case',unknownCase,'unknown_bundle',unknownBundle, ...
    'short_interval',short,'wrong_units',wrongUnits,'stopped_wrong_units',stopped, ...
    'missing_channel',missingInput,'stopped_missing_channel',stoppedMissing));
report = struct('experiment_id','EXP-20261019-010','user_stage',2,'step',6, ...
    'passed',all([checks.passed]),'checks_passed',nnz([checks.passed]), ...
    'check_count',numel(checks),'checks',checks,'registered_tools',6, ...
    'case_chains',7,'public_chain_calls',56,'new_physical_runs',0,'llm_calls',0, ...
    'scope','deterministic_tool_integration_not_llm_or_diagnostic_performance');
writeJson(fullfile(out,'acceptance.json'),report);
fprintf('tool layer: %d/%d checks; 7 chains, 56 public calls, 0 LLM calls.\n', ...
    report.checks_passed,report.check_count);
assert(report.passed,'LayerTest:acceptance_failed','Review tool-layer acceptance.');

    function add(name,yes)
        checks(end+1) = struct('name',name,'passed',logical(yes));
    end
    function value = invoke(name,payload)
        value = ema_tool(name,payload);
        trace = [trace;struct('step',numel(trace)+1,'tool',name,'arguments',payload,'response',value)];
    end
end

function yes = commonContract(v,registry)
required = {'tool','tool_version','case_id','status','error_code','input_hash', ...
    'parameter_version','model_hash','preconditions','result','evidence','warnings','duration_ms'};
entry = registry.tools(strcmp({registry.tools.name},v.tool));
yes = all(isfield(v,required)) && isscalar(entry) && strcmp(v.tool_version,entry.version) && ...
    ismember(v.status,{'ok','not_applicable','insufficient_data','execution_error'}) && ...
    isfinite(v.duration_ms) && v.duration_ms>=0 && finiteNumbers(v) && isempty(v.model_hash);
end

function yes = safeResponse(v)
text = jsonencode(v);
yes = isempty(regexpi(text,'EXP-\d{8}|injected_|appliedFault|evaluation_private|legacy_private|(?<![a-z0-9])[a-z]:[\\/]|secret','once')) && ...
    noBlockedKeys(v) && finiteNumbers(v);
end

function yes = noBlockedKeys(v)
yes = true;
if isstruct(v)
    names = fieldnames(v);
    blocked = {'config','appliedFault','label','fault_label','injected_fault','observations','residuals', ...
        'time_s','x_meas_m','omega_meas_radps','iabc_meas_A','id_meas_A','iq_meas_A','x_ref_m'};
    yes = ~any(ismember(names,blocked));
    for k = 1:numel(v)
        for j = 1:numel(names), yes = yes && noBlockedKeys(v(k).(names{j})); end
    end
elseif iscell(v)
    yes = all(cellfun(@noBlockedKeys,v));
end
end

function yes = finiteNumbers(v)
yes = true;
if isnumeric(v), yes = all(isfinite(v(:)));
elseif isstruct(v)
    names = fieldnames(v);
    for k = 1:numel(v)
        for j = 1:numel(names), yes = yes && finiteNumbers(v(k).(names{j})); end
    end
elseif iscell(v), yes = all(cellfun(@finiteNumbers,v));
end
end

function state = precondition(v,name)
rows = v.preconditions(strcmp({v.preconditions.name},name));
state = '';
if ~isempty(rows) && isscalar(unique({rows.state})), state = rows(1).state; end
end

function rows = protectedHashes(root)
files = jsondecode(fileread(fullfile(root,'results','EXP-20261019-009','final','protected_hashes_after.json')));
rows = files;
for k = 1:numel(files)
    rows(k).sha256 = tool_sha256(fullfile(root,files(k).path),'file');
    assert(strcmp(rows(k).sha256,files(k).sha256),'LayerTest:protected_input_changed','Protected input changed.');
end
plots = dir(fullfile(root,'data','agent_visible','figures_v1','PLOT-*','*'));
plots = plots(~[plots.isdir]);
for k = 1:numel(plots)
    path = fullfile(plots(k).folder,plots(k).name);
    rows(end+1) = struct('path',path(numel(root)+2:end),'sha256',tool_sha256(path,'file')); %#ok<AGROW>
end
end

function reseal(folder,sourceManifest,targetManifest)
manifest = jsondecode(fileread(sourceManifest));
for k = 1:numel(manifest.files)
    path = fullfile(folder,manifest.files(k).path);
    if isfile(path), manifest.files(k).sha256 = tool_sha256(path,'file'); end
end
writeJson(targetManifest,manifest);
end

function writeJson(path,value)
h = fopen(path,'w','n','UTF-8'); assert(h>=0);
cleanup = onCleanup(@() fclose(h)); fprintf(h,'%s',jsonencode(value,'PrettyPrint',true));
end
