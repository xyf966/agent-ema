function response = lookup_conditions_core(methodId,caseId,release,manifest,registry)
response = struct('tool','lookup_method_conditions','tool_version','EMA-METHOD-LOOKUP-1.0', ...
    'case_id',caseId,'status','execution_error','error_code','','input_hash','', ...
    'parameter_version','','model_hash','','method_version','EMA-METHODS-1.0', ...
    'preconditions',[],'result',struct(),'evidence',[],'warnings',{{}},'duration_ms',0);
try
    path = fullfile(registry,'method_conditions_v1.json');
    descriptor = jsondecode(fileread(fullfile(registry,'method_conditions_version.json')));
    ruleHash = tool_sha256(path,'file');
    require(strcmp(descriptor.method_version,response.method_version) && ...
        strcmp(descriptor.rules_sha256,ruleHash),'method_rules_integrity_mismatch');
    table = jsondecode(fileread(path));
    require(hasKeys(table,{'method_version','scope','methods'}) && ...
        strcmp(table.method_version,response.method_version) && ...
        strcmp(table.scope,'generic_physical_conditions_no_case_answers'),'invalid_method_table');
    allowed = ["position_consistency","phase_sum","torque_balance","motion_validity", ...
        "alarm_persistence","cross_channel_response","hypothesis_comparison"];
    conditionIds = {'numeric_input_contract','three_phase_acquisition','independent_initial_reference', ...
        'nominal_parameter_record','valid_motion_window','explicit_compensation_basis', ...
        'independent_normal_load','cross_channel_alternatives_checked','data_window_coverage', ...
        'residual_grid_and_finiteness','threshold_version_compatible','noise_calibration_available', ...
        'independent_corroboration','hypotheses_distinguishable'};
    require(isstruct(table.methods) && numel(table.methods)==7 && ...
        isequal(sort(string({table.methods.method_id})),sort(allowed)),'invalid_method_table');
    for k = 1:numel(table.methods)
        m = table.methods(k);
        require(hasKeys(m,{'method_id','title_zh','purpose_zh','plain_explanation_zh','conditions', ...
            'supported_uses_zh','limitations_zh','prohibited_claims_zh','next_checks','source_refs'}),'invalid_method_table');
        require(isstruct(m.conditions) && all(arrayfun(@(v) hasKeys(v,{'id','scope','description_zh'}) && ...
            ismember(v.id,conditionIds) && ismember(v.scope,{'calculation','interpretation','confirmation'}),m.conditions)), ...
            'invalid_method_table');
    end
    if ~strcmp(methodId,'all'), table.methods = table.methods(strcmp({table.methods.method_id},methodId)); end
    require(~isempty(table.methods),'unsupported_method_id');
    inspection = struct(); caseHash = 'not_requested'; parameterHash = 'not_read';
    nominalState = 'unknown'; nominalSource = 'not_checked_by_this_query'; caseUnavailable = false;
    if ~isempty(caseId)
        inspection = inspect_case_core(caseId,release,manifest);
        if strcmp(inspection.status,'execution_error')
            response.status = inspection.status; response.error_code = inspection.error_code; return;
        end
        caseUnavailable = ~isfield(inspection.result,'channels');
        caseHash = inspection.input_hash; response.parameter_version = inspection.parameter_version;
        response.warnings = inspection.warnings;
        if ~caseUnavailable && any(strcmp({table.methods.method_id},'torque_balance'))
            try
                [p,parameterHash] = read_residual_input(release,manifest,'parameters');
                nominalState = nominalRecordState(p);
                nominalSource = 'approved_nominal_parameter_record';
            catch issue
                if strcmp(issue.identifier,'Residual:missing_artifact')
                    parameterHash = 'unavailable';
                    nominalSource = 'nominal_parameter_record_unavailable';
                else
                    rethrow(issue);
                end
            end
        end
    end
    response.input_hash = tool_sha256(strjoin({'EMA-METHOD-LOOKUP-1.0',ruleHash, ...
        methodId,caseId,caseHash,parameterHash},'|'),'text');
    methods = struct([]); evidence = struct([]); preconditions = struct([]);
    for k = 1:numel(table.methods)
        m = table.methods(k); assessed = struct([]);
        ev = ['METHOD-' response.input_hash '-' num2str(k)];
        for j = 1:numel(m.conditions)
            condition = m.conditions(j); state = 'unknown'; source = 'not_checked_by_this_query';
            if ~isempty(caseId) && ~caseUnavailable
                switch condition.id
                    case 'numeric_input_contract'
                        state = stateOf(strcmp(inspection.status,'ok')); source = 'approved_case_input_check';
                    case 'three_phase_acquisition'
                        state = inspection.preconditions(2).state; source = 'approved_acquisition_metadata';
                    case 'nominal_parameter_record'
                        state = nominalState; source = nominalSource;
                    case 'data_window_coverage'
                        counts = [inspection.result.channels.sample_count];
                        state = stateOf(all(counts>=2001)); source = 'approved_channel_lengths';
                    case {'independent_initial_reference','independent_normal_load'}
                        source = 'information_unavailable_in_approved_metadata';
                end
            end
            condition.state = state; condition.state_source = source; condition.evidence_id = ev;
            assessed = [assessed;condition]; %#ok<AGROW>
            preconditions = [preconditions;struct('name',condition.id,'state',state,'evidence_id',ev)]; %#ok<AGROW>
        end
        m.conditions = assessed;
        methods = [methods;m]; %#ok<AGROW>
        evidence = [evidence;struct('id',ev,'quantity',m.method_id,'unit','rule', ...
            'time_range_s',[],'valid',true,'source',response.method_version)]; %#ok<AGROW>
    end
    response.status = 'ok';
    if caseUnavailable
        response.status = 'insufficient_data'; response.error_code = 'case_context_unavailable';
    end
    scope = 'general_method_knowledge';
    if ~isempty(caseId), scope = 'rules_and_limited_case_metadata_assessment'; end
    response.result = struct('scope',scope,'method_version',response.method_version, ...
        'rules_sha256',ruleHash,'methods',methods,'contains_case_diagnosis',false, ...
        'unresolved_conditions_remain_unknown',true);
    response.evidence = evidence; response.preconditions = preconditions;
    response.warnings{end+1} = 'RULE_LOOKUP_DOES_NOT_PROVE_FAULT_CAUSE';
    response.warnings{end+1} = 'MOTION_AND_RESIDUAL_CONDITIONS_REQUIRE_NUMERICAL_EVIDENCE';
catch issue
    response.status = 'execution_error'; response.error_code = 'internal_execution_error';
    if startsWith(issue.identifier,'Method:')
        response.error_code = extractAfter(issue.identifier,'Method:');
    elseif startsWith(issue.identifier,'Residual:')
        response.error_code = extractAfter(issue.identifier,'Residual:');
    end
    response.result = struct(); response.evidence = []; response.preconditions = [];
end
end

function state = nominalRecordState(p)
state = 'violated';
if ~hasKeys(p,{'parameter_version','nominal'}) || ~strcmp(p.parameter_version,'EMA-NOMINAL-1.0') || ...
        ~hasKeys(p.nominal,{'motor','mechanics'}), return; end
if ~hasKeys(p.nominal.motor,{'polePairs','flux_Wb','Ld_H','Lq_H','rotorInertia_kgm2','viscousDamping_NmsPerRad'}) || ...
        ~hasKeys(p.nominal.mechanics,{'screwLead_mPerRev','gearRatio','efficiency','coulombFriction_N','viscousFriction_NsPerM'}), return; end
for group = {'motor','mechanics'}
    if ~all(structfun(@(v) isa(v,'double') && isscalar(v) && isreal(v) && ...
            isfinite(v) && v>=0,p.nominal.(group{1}))), return; end
end
m = p.nominal.mechanics;
if m.screwLead_mPerRev>0 && m.gearRatio>0 && m.efficiency>0 && m.efficiency<=1 && ...
        p.nominal.motor.polePairs>=1 && mod(p.nominal.motor.polePairs,1)==0
    state = 'satisfied';
end
end

function state = stateOf(yes)
state = 'violated'; if yes, state = 'satisfied'; end
end

function yes = hasKeys(value,names)
yes = isstruct(value) && isscalar(value) && ...
    isequal(sort(string(fieldnames(value))),sort(string(names(:))));
end

function require(yes,code)
assert(isscalar(yes) && yes,['Method:' code],'Method query failed.');
end
