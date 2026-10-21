function report = test_stage4_boundary_layer()
% Research-only integration checks on real saved data; no sim or LLM calls.
root = fileparts(fileparts(mfilename('fullpath')));
out = fullfile(root,'results','EXP-20261020-018');
assert(~isfile(fullfile(out,'tool_acceptance.json')),'Paper:ExistingTest','Preserve completed tests.');
mapping = jsondecode(fileread(fullfile(root,'data/evaluation_private/EXP-20261020-018/case_mapping.json')));
checks = struct('name',{},'passed',{}); traces = struct('tool',{},'arguments',{},'response',{});
for k=1:2
    cid = mapping(k).case_id; prefix = sprintf('case%d_',k);
    inspection = call('inspect_case',struct('case_id',cid));
    context = call('query_operating_context',struct('case_id',cid));
    methods = call('lookup_method_conditions',struct('case_id',cid,'method_id','all'));
    add([prefix 'inspection_ok'],strcmp(inspection.status,'ok') && inspection.result.numeric_input_ready);
    add([prefix 'same_physical_group'],strcmp(inspection.result.group_id,mapping(k).group_id));
    add([prefix 'methods_generic_only'],strcmp(methods.status,'ok') && ~methods.result.contains_case_diagnosis);
    rows = context.result.records;
    cmd = rows(strcmp({rows.name},'load_command')); assumed = rows(strcmp({rows.name},'load_compensation'));
    independent = rows(strcmp({rows.name},'independent_load')); initial = rows(strcmp({rows.name},'initial_reference'));
    add([prefix 'source_roles_distinct'],strcmp(cmd.source_kind,'prescribed_test_command') && ...
        strcmp(assumed.source_kind,'recorded_diagnostic_assumption') && ~strcmp(cmd.source_id,assumed.source_id));
    add([prefix 'true_command_record_preserved'],cmd.value.force_max_N==1500+300*(k-1));
    add([prefix 'recorded_compensation_1500N'],assumed.value.force_max_N==1500 && assumed.value.explicit_assumption_required);
    add([prefix 'no_independent_load_or_reference'],~independent.value.available && ~initial.value.available);
    reference = load(fullfile(root,'results',mapping(k).source_run_id,'residuals.mat'));
    bundles = cell(1,3); modes = {'none','prescribed_command','recorded_assumption'};
    for m=1:3
        r = call('compute_residual_bundle',struct('case_id',cid,'load_assumption',modes{m}));
        add([prefix modes{m} '_compute_ok'],strcmp(r.status,'ok') && ~r.result.independent_load_supported);
        bundles{m} = r.result.bundle_id;
        a = call('locate_anomalies',struct('residual_evidence_id',bundles{m}));
        add([prefix modes{m} '_anomalies_ok'],strcmp(a.status,'ok') && strcmp(a.case_id,cid));
        saved = load(fullfile(root,'data/agent_visible/derived_boundary_v1',bundles{m},'residuals.mat'),'residuals');
        add([prefix modes{m} '_finite_arrays'],all(structfun(@(v) all(isfinite(v(:))),saved.residuals)));
        if m==1
            add([prefix 'no_assumption_no_compensated_detection'],~isfield(saved.residuals,'torque_known_load_Nm') && ...
                strcmp(a.result.channels(3).status,'insufficient_data') && ~a.result.channels(3).detector_executed);
        else
            expected = reference.correctResiduals;
            if m==3, expected = reference.residuals; end
            quantities = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
            for q=1:3
                delta = max(abs(saved.residuals.(quantities{q})-expected.(quantities{q})));
                add([prefix modes{m} '_numeric_' quantities{q}],delta<1e-12);
            end
            post = jsondecode(fileread(fullfile(root,'results',mapping(k).source_run_id,'postprocess_report.json')));
            expectedAlarm = post.correct_command_alarms;
            if m==3, expectedAlarm = post.diagnostic_assumption_alarms; end
            add([prefix modes{m} '_alarm_flags'],isequal([a.result.channels.alarmed],[expectedAlarm.alarmed]));
            timesEqual = true;
            for q=1:3
                timesEqual = timesEqual && isequal(a.result.channels(q).first_alarm_s,expectedAlarm(q).first_alarm_s);
            end
            add([prefix modes{m} '_alarm_times'],timesEqual);
            basis = 'command_derived_compensation_assumption';
            if m==3, basis = 'recorded_diagnostic_assumption_not_measurement'; end
            add([prefix modes{m} '_correct_compensation_provenance'],strcmp(a.result.channels(3).interpretation_basis,basis));
        end
    end
    add([prefix 'three_distinct_source_bound_bundles'],numel(unique(bundles))==3);
    p = call('plot_evidence',struct('residual_evidence_id',bundles{3}));
    add([prefix 'plot_same_case_and_bundle'],strcmp(p.status,'ok') && strcmp(p.case_id,cid) && ...
        strcmp(p.result.residual_evidence_id,bundles{3}) && strcmp(p.result.load_assumption,'recorded_assumption'));
    folder = fullfile(root,'data/agent_visible/figures_boundary_v1',p.result.plot_id);
    add([prefix 'plot_files_hashes'],strcmp(p.result.png_sha256,paper_file_sha256(fullfile(folder,'overview.png'))) && ...
        strcmp(p.result.fig_sha256,paper_file_sha256(fullfile(folder,'overview.fig'))));
    f = openfig(fullfile(folder,'overview.fig'),'invisible');
    line = findobj(f,'Type','Line','Tag','torque_known_load_Nm');
    expected = reference.residuals.torque_known_load_Nm; expected(~reference.residuals.motion_valid) = NaN;
    plotted = get(line,'YData');
    mask = isfinite(expected);
    add([prefix 'plot_curve_matches_saved_reference'],isequal(size(plotted(:)),size(expected(:))) && ...
        all(isnan(plotted(~mask))) && max(abs(plotted(mask)-expected(mask)'))<1e-12);
    close(f);
end
% Seven legacy cases keep their original numerical inputs and bundle identity.
old = jsondecode(fileread(fullfile(root,'results/EXP-20261019-010/final/case_chain_summary.json')));
for k=1:numel(old)
    i = call('inspect_case',struct('case_id',old(k).case_id));
    r = call('compute_residual_bundle',struct('case_id',old(k).case_id,'load_assumption','prescribed_command'));
    add(sprintf('legacy%d_inspection_and_bundle_unchanged',k),strcmp(i.status,'ok') && ...
        strcmp(i.result.group_id,old(k).group_id) && strcmp(r.result.bundle_id,old(k).compensated_bundle_id));
end
cid = mapping(1).case_id;
negative = {
    'inspect_case',struct('case_id',cid,'path','C:\unapproved.mat');
    'compute_residual_bundle',struct('case_id',cid,'load_assumption','private_truth');
    'query_operating_context',struct('case_id',cid,'fields',{{'appliedFault'}});
    'lookup_method_conditions',struct('case_id',cid,'method_id','private_answer');
    'locate_anomalies',struct('residual_evidence_id','BUNDLE-invalid');
    'plot_evidence',struct('residual_evidence_id','BUNDLE-invalid')};
for k=1:size(negative,1)
    r = call(negative{k,1},negative{k,2});
    add(['negative_' negative{k,1}],strcmp(r.status,'execution_error') && isempty(r.evidence));
end
for k=1:numel(traces)
    if strcmp(traces(k).response.status,'execution_error'), continue; end
    serialized = jsonencode(traces(k).response);
    add(sprintf('response%d_no_truth_container_or_source_label',k), ...
        ~contains(serialized,'private_position_true_m') && ~contains(serialized,'reference_class') && ...
        ~contains(serialized,'applied_parameters') && ~contains(serialized,'evaluation_private') && ...
        ~contains(serialized,'generation.mat') && ~contains(serialized,'injected_'));
end
report = struct('experiment_id','EXP-20261020-018','user_stage',4,'step',2, ...
    'passed',all([checks.passed]),'check_count',numel(checks),'checks_passed',nnz([checks.passed]), ...
    'checks',checks,'actual_dispatch_calls',numel(traces),'new_simulations',0,'llm_calls',0, ...
    'current_agent_worker_switched',false);
writeJson(fullfile(out,'tool_call_traces.json'),traces);
writeJson(fullfile(out,'tool_acceptance.json'),report);
assert(report.passed,'Paper:BoundaryToolChecks','Some boundary checks failed. Preserve results.');
fprintf('Boundary integration checks: %d/%d; dispatch calls %d.\n',report.checks_passed,report.check_count,numel(traces));

    function add(name,condition)
        checks(end+1) = struct('name',name,'passed',logical(condition));
    end

    function value = call(name,arguments)
        value = ema_tool_stage4(name,arguments);
        traces(end+1) = struct('tool',name,'arguments',arguments,'response',value);
    end
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8');
assert(handle>=0,'Paper:Write','Cannot write test report.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
