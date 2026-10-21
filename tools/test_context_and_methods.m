function report = test_context_and_methods(reportFolder)
% Research-only tests of truthful context, frozen rules, and bounded access.
root = fileparts(fileparts(mfilename('fullpath')));
if nargin==0, reportFolder = fullfile(root,'results','EXP-20261019-008'); end
out = char(java.io.File(reportFolder).getCanonicalPath());
base = char(java.io.File(fullfile(root,'results')).getCanonicalPath());
require(startsWith(lower(out),lower([base filesep])) && ...
    ~isfile(fullfile(out,'acceptance.json')),'new_project_report_required');
if ~isfolder(out), mkdir(out); end
release = fullfile(root,'data','agent_visible','observations_v1');
registry = fullfile(root,'tools','registry');
manifest = fullfile(registry,'observations_v1_manifest.json');
catalog = jsondecode(fileread(fullfile(release,'catalog.json')));
checks = struct('name',{},'passed',{},'status',{},'error_code',{});
responses = cell(7,2);
for k = 1:7
    id = catalog.cases(k).case_id;
    c = query_operating_context(id); m = lookup_method_conditions('all',id);
    responses{k,1} = c; responses{k,2} = m;
    records = c.result.records;
    checks(end+1) = item(['actual_context_' num2str(k)],strcmp(c.status,'ok') && ...
        numel(records)==5 && c.result.partial_result && ...
        ~records(1).value.independent_measurement && records(2).value.explicit_assumption_required && ...
        records(1).value.force_min_N==-1500 && records(1).value.force_max_N==1500,c); %#ok<AGROW>
    checks(end+1) = item(['missing_independent_information_' num2str(k)], ...
        strcmp(records(3).status,'insufficient_data') && ~records(3).value.available && ...
        strcmp(records(4).status,'insufficient_data') && ~records(4).value.available && ...
        isempty(records(3).time_range_s),c); %#ok<AGROW>
    checks(end+1) = item(['method_conditions_not_assumed_' num2str(k)],strcmp(m.status,'ok') && ...
        numel(m.result.methods)==7 && ~m.result.contains_case_diagnosis && ...
        strcmp(conditionState(m,'position_consistency','independent_initial_reference'),'unknown') && ...
        strcmp(conditionState(m,'torque_balance','independent_normal_load'),'unknown') && ...
        strcmp(conditionState(m,'torque_balance','nominal_parameter_record'),'satisfied') && ...
        strcmp(conditionState(m,'motion_validity','valid_motion_window'),'unknown'),m); %#ok<AGROW>
    positive = query_operating_context(id,{'load_command'},[0.05,0.18]);
    checks(end+1) = item(['positive_command_scope_' num2str(k)],strcmp(positive.status,'ok') && ...
        positive.result.records.value.force_min_N==1500 && ...
        positive.result.records.value.force_max_N==1500,positive); %#ok<AGROW>
    negative = query_operating_context(id,{'load_command'},[0.55,0.68]);
    checks(end+1) = item(['negative_command_scope_' num2str(k)],strcmp(negative.status,'ok') && ...
        negative.result.records.value.force_min_N==-1500 && ...
        negative.result.records.value.force_max_N==-1500,negative); %#ok<AGROW>
end
id = catalog.cases(1).case_id;
generic = lookup_method_conditions('all');
checks(end+1) = item('general_rules_do_not_assess_unseen_case',strcmp(generic.status,'ok') && ...
    isempty(generic.case_id) && all(strcmp({generic.preconditions.state},'unknown')),generic);
repeat = lookup_method_conditions('all');
checks(end+1) = item('same_rules_stable_evidence', ...
    isequal(rmfield(generic,'duration_ms'),rmfield(repeat,'duration_ms')),repeat);
onlyMissing = query_operating_context(id,{'independent_load','initial_reference'});
checks(end+1) = expected('only_missing_information_is_insufficient',onlyMissing,'insufficient_data','requested_information_unavailable');
outside = query_operating_context(id,{'load_command'},[1,2]);
checks(end+1) = item('outside_scope_is_not_zero_load',strcmp(outside.status,'insufficient_data') && ...
    ~outside.result.records.value.available && ~isfield(outside.result.records.value,'force_min_N'),outside);
sparse = query_operating_context(id,{'load_command'},[0.0201,0.0204]);
checks(end+1) = item('no_record_samples_are_not_invented',strcmp(sparse.status,'insufficient_data') && ...
    strcmp(sparse.result.records.error_code,'no_record_samples_in_interval'),sparse);
partial = query_operating_context(id,{'signal_acquisition'},[0.7,1]);
checks(end+1) = item('partial_time_coverage_explicit',strcmp(partial.status,'ok') && ...
    ~partial.result.coverage_complete && isequal(partial.result.effective_time_range_s,[0.7,0.8]),partial);
bad = query_operating_context('../private/hidden.mat');
checks(end+1) = expected('context_path_rejected',bad,'execution_error','invalid_case_id');
bad = query_operating_context(id,{'config'});
checks(end+1) = expected('unapproved_field_rejected',bad,'execution_error','invalid_context_fields');
bad = query_operating_context(id,{'independent_load','independent_load'});
checks(end+1) = expected('duplicate_fields_rejected',bad,'execution_error','invalid_context_fields');
bad = query_operating_context(id,{'load_command'},[0.2,0.1]);
checks(end+1) = expected('reversed_range_rejected',bad,'execution_error','invalid_time_range');
bad = query_operating_context(id,{'load_command'},[0,NaN]);
checks(end+1) = expected('nonfinite_range_rejected',bad,'execution_error','invalid_time_range');
bad = ema_tool('query_operating_context',struct('case_id',id,'path','private'));
checks(end+1) = expected('context_extra_path_rejected',bad,'execution_error','invalid_arguments');
bad = lookup_method_conditions('../private/rules');
checks(end+1) = expected('method_path_rejected',bad,'execution_error','invalid_method_id');
bad = lookup_method_conditions('phase_sum','../private/case');
checks(end+1) = expected('method_case_path_rejected',bad,'execution_error','invalid_case_id');
bad = ema_tool('lookup_method_conditions',struct('method_id','all','method_version','other'));
checks(end+1) = expected('unknown_rule_version_rejected',bad,'execution_error','invalid_method_version');
bad = ema_tool('lookup_method_conditions',struct('method_id','all','file','private'));
checks(end+1) = expected('method_extra_argument_rejected',bad,'execution_error','invalid_arguments');
unknown = ['CASE-' repmat('0',1,32)];
bad = query_operating_context(unknown);
checks(end+1) = expected('unknown_context_case_reported',bad,'insufficient_data','case_not_found');
bad = lookup_method_conditions('all',unknown);
checks(end+1) = item('unknown_case_does_not_gain_conditions', ...
    strcmp(bad.status,'insufficient_data') && all(strcmp({bad.preconditions.state},'unknown')),bad);
% Private copies can be approved for data-quality tests, never via Agent args.
private = fullfile(root,'data','evaluation_private','EXP-20261019-008');
if ~isfolder(private), mkdir(private); end
token = char(java.util.UUID.randomUUID());
fixture = fullfile(private,['release_' token]);
[ok,message] = copyfile(release,fixture); assert(ok,'%s',message);
fixtureManifest = fullfile(private,['manifest_' token '.json']);
scenarios = {'missing_command','nonfinite_command','unapproved_command','missing_time', ...
    'reconstructed_phase','metadata_text','missing_parameters','invalid_parameters','unapproved_parameters'};
for k = 1:numel(scenarios)
    changed = {'operating_context.mat','operating_context.json','channel_contract.json','parameters.json', ...
        [id '/observations.mat'],[id '/metadata.json']};
    for j = 1:numel(changed), copyfile(fullfile(release,changed{j}),fullfile(fixture,changed{j}),'f'); end
    scenario = scenarios{k}; reseal = true;
    switch scenario
        case 'missing_command', delete(fullfile(fixture,'operating_context.mat'));
        case 'missing_time'
            path = fullfile(fixture,id,'observations.mat'); s = load(path);
            observations = rmfield(s.observations,'time_s'); save(path,'observations','-v7');
            meta = jsondecode(fileread(fullfile(fixture,id,'metadata.json')));
            meta.observations_sha256 = tool_sha256(path,'file');
            writeJson(fullfile(fixture,id,'metadata.json'),meta);
        case {'nonfinite_command','unapproved_command'}
            s = load(fullfile(fixture,'operating_context.mat')); command = s.command;
            command.compensation_force_N(3) = NaN;
            save(fullfile(fixture,'operating_context.mat'),'command','-v7');
            reseal = ~strcmp(scenario,'unapproved_command');
        case 'reconstructed_phase'
            c = jsondecode(fileread(fullfile(fixture,'channel_contract.json')));
            c.phase_acquisition = 'third_phase_reconstructed'; writeJson(fullfile(fixture,'channel_contract.json'),c);
        case 'metadata_text'
            c = jsondecode(fileread(fullfile(fixture,'operating_context.json')));
            c.limitation = 'F1 EXP-20261016-001 C:\private\secret.mat';
            writeJson(fullfile(fixture,'operating_context.json'),c);
        case 'missing_parameters', delete(fullfile(fixture,'parameters.json'));
        case {'invalid_parameters','unapproved_parameters'}
            p = jsondecode(fileread(fullfile(fixture,'parameters.json'))); p.nominal.mechanics.efficiency = 0;
            writeJson(fullfile(fixture,'parameters.json'),p); reseal = ~strcmp(scenario,'unapproved_parameters');
    end
    m = jsondecode(fileread(manifest));
    if reseal
        for j = 1:numel(m.files)
            path = fullfile(fixture,m.files(j).path);
            if isfile(path), m.files(j).sha256 = tool_sha256(path,'file'); end
        end
    end
    writeJson(fixtureManifest,m);
    c = query_context_core(id,{'load_command','load_compensation','signal_acquisition'},[],fixture,fixtureManifest);
    rules = lookup_conditions_core('all',id,fixture,fixtureManifest,registry);
    passed = true;
    switch scenario
        case {'missing_command','nonfinite_command'}
            passed = strcmp(c.status,'ok') && c.result.partial_result && ...
                strcmp(c.result.records(1).status,'insufficient_data') && ...
                ~c.result.records(1).source_verified && ~c.result.records(1).value.available;
            selective = query_context_core(id,{'independent_load'},[],fixture,fixtureManifest);
            passed = passed && strcmp(selective.status,'insufficient_data');
        case 'unapproved_command', passed = strcmp(c.status,'execution_error') && strcmp(c.error_code,'integrity_mismatch');
        case 'missing_time', passed = strcmp(c.status,'insufficient_data') && strcmp(c.error_code,'case_time_coverage_unavailable');
        case 'reconstructed_phase'
            passed = strcmp(c.result.records(3).value.phase_acquisition_state,'violated') && ...
                strcmp(conditionState(rules,'phase_sum','three_phase_acquisition'),'violated');
        case 'metadata_text', passed = strcmp(c.status,'ok') && strcmp(rules.status,'ok');
        case 'missing_parameters', passed = strcmp(conditionState(rules,'torque_balance','nominal_parameter_record'),'unknown');
        case 'invalid_parameters', passed = strcmp(conditionState(rules,'torque_balance','nominal_parameter_record'),'violated');
        case 'unapproved_parameters', passed = strcmp(rules.status,'execution_error') && strcmp(rules.error_code,'integrity_mismatch');
    end
    assertSafe(c); assertSafe(rules);
    checks(end+1) = item(['fixture_' scenario],passed,c); %#ok<AGROW>
end
fixtureRegistry = fullfile(private,['registry_' token]);
[ok,message] = copyfile(registry,fixtureRegistry); assert(ok,'%s',message);
ruleTable = jsondecode(fileread(fullfile(fixtureRegistry,'method_conditions_v1.json')));
ruleTable.methods(1).plain_explanation_zh = 'secret';
writeJson(fullfile(fixtureRegistry,'method_conditions_v1.json'),ruleTable);
bad = lookup_conditions_core('all','',release,manifest,fixtureRegistry);
checks(end+1) = expected('unapproved_rule_change_rejected',bad,'execution_error','method_rules_integrity_mismatch');
% Generic knowledge must not contain any public case/group identifiers.
text = fileread(fullfile(registry,'method_conditions_v1.json'));
noCaseAnswers = isempty(regexp(text,'CASE-|RUN-|EXP-\d{8}','once'));
checks(end+1) = item('generic_rule_table_has_no_case_mapping',noCaseAnswers,generic);
files = {'ema_tool.m','query_operating_context.m','lookup_method_conditions.m', ...
    'private/query_context_core.m','private/lookup_conditions_core.m','test_context_and_methods.m'};
lint = struct('file',{},'message_count',{},'messages',{});
for k = 1:numel(files)
    issues = checkcode(fullfile(root,'tools',files{k}),'-id');
    lint(end+1) = struct('file',files{k},'message_count',numel(issues),'messages',issues); %#ok<AGROW>
end
report = struct('experiment_id','EXP-20261019-008','stage',2,'step',4, ...
    'passed',all([checks.passed]) && all([lint.message_count]==0), ...
    'case_count',7,'generic_method_count',7,'new_physical_runs',0,'llm_agent_calls',0, ...
    'checks',checks,'code_analyzer',lint,'completed_at',char(datetime('now','TimeZone','Asia/Shanghai')));
writeJson(fullfile(out,'acceptance.json'),report); writeJson(fullfile(out,'case_responses.json'),responses);
writeJson(fullfile(out,'generic_method_response.json'),generic);
require(report.passed,'acceptance_failed');
fprintf('Context and methods: %d/%d checks passed; seven anonymous cases and seven generic methods.\n', ...
    nnz([checks.passed]),numel(checks));
end

function state = conditionState(response,method,id)
rules = response.result.methods;
rule = rules(strcmp({rules.method_id},method));
condition = rule.conditions(strcmp({rule.conditions.id},id)); state = condition.state;
end

function value = expected(name,response,status,code)
value = item(name,strcmp(response.status,status) && strcmp(response.error_code,code),response);
end

function value = item(name,passed,response)
assertSafe(response);
value = struct('name',name,'passed',passed,'status',response.status,'error_code',response.error_code);
end

function assertSafe(response)
blocked = '(?i)(EXP-\d{8}|(?<![a-z0-9])F[123](?![a-z0-9])|healthy|gradual|injected_|evaluation_private|legacy_private|(?<![a-z])[a-z]:[\\/]|secret)';
require(isempty(regexp(jsonencode(response),blocked,'once')),'response_leak');
end

function require(yes,code)
assert(isscalar(yes) && yes,['ContextTest:' code],'Context and methods acceptance failed.');
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8'); assert(handle>=0);
cleanup = onCleanup(@() fclose(handle)); fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
