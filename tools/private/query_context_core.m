function response = query_context_core(caseId,fields,interval,release,manifest)
response = struct('tool','query_operating_context','tool_version','EMA-CONTEXT-1.0', ...
    'case_id',caseId,'status','execution_error','error_code','','input_hash','', ...
    'parameter_version','','model_hash','','preconditions',[],'result',struct(), ...
    'evidence',[],'warnings',{{}},'duration_ms',0);
try
    inspection = inspect_case_core(caseId,release,manifest);
    if strcmp(inspection.status,'execution_error') || ~isfield(inspection.result,'time_range_s')
        response.status = inspection.status; response.error_code = inspection.error_code;
        return;
    end
    response.parameter_version = inspection.parameter_version;
    response.preconditions = inspection.preconditions;
    response.warnings = inspection.warnings;
    coverage = inspection.result.time_range_s;
    if numel(coverage)~=2
        response.status = 'insufficient_data'; response.error_code = 'case_time_coverage_unavailable';
        return;
    end
    if isempty(interval), interval = coverage; end
    effective = [max(interval(1),coverage(1)),min(interval(2),coverage(2))];
    if effective(1)>effective(2), effective = []; end
    complete = interval(1)>=coverage(1) && interval(2)<=coverage(2);
    command = struct(); commandHash = 'not_requested'; commandError = '';
    if any(ismember(fields,{'load_command','load_compensation'})) && ~isempty(effective)
        try
            [command,commandHash] = read_residual_input(release,manifest,'command');
            allowed = {'time_s','external_force_command_N','direct_torque_command_Nm', ...
                'compensation_time_s','compensation_force_N','compensation_direct_torque_Nm'};
            require(isstruct(command) && isscalar(command) && ...
                isequal(sort(string(fieldnames(command))),sort(string(allowed(:)))),'invalid_context_structure');
            good = all(structfun(@(v) isa(v,'double') && isreal(v) && ...
                iscolumn(v) && ~isempty(v) && all(isfinite(v)),command));
            good = good && all(diff(command.time_s)>0) && ...
                all(diff(command.compensation_time_s)>0) && ...
                isequal(size(command.time_s),size(command.external_force_command_N),size(command.direct_torque_command_Nm)) && ...
                isequal(size(command.compensation_time_s),size(command.compensation_force_N),size(command.compensation_direct_torque_Nm));
            if ~good, commandError = 'invalid_command_data'; end
        catch issue
            if strcmp(issue.identifier,'Residual:missing_artifact')
                commandHash = 'unavailable'; commandError = 'command_record_unavailable';
            else
                rethrow(issue);
            end
        end
    end
    response.input_hash = tool_sha256(strjoin({'EMA-CONTEXT-1.0',caseId,inspection.input_hash, ...
        jsonencode(fields),jsonencode(interval),commandHash},'|'),'text');
    records = struct([]); evidence = struct([]);
    for k = 1:numel(fields)
        field = fields{k};
        row = struct('name',field,'status','insufficient_data','error_code','', ...
            'source_id','','source_kind','unavailable','source_verified',true, ...
            'independence','unknown','time_range_s',[],'value',struct('available',false), ...
            'interpretation_limit','','evidence_id',['CTX-' response.input_hash '-' num2str(k)]);
        switch field
            case {'load_command','load_compensation'}
                row.source_id = 'CTX-PRESCRIBED-1.0';
                row.source_verified = false;
                row.independence = 'not_independent_measurement';
                row.source_kind = 'prescribed_test_command';
                row.interpretation_limit = 'COMMAND_DOES_NOT_ESTABLISH_ACTUAL_LOAD';
                if strcmp(field,'load_compensation')
                    row.source_kind = 'command_derived_diagnostic_assumption';
                    row.interpretation_limit = 'EXPLICIT_ASSUMPTION_REQUIRED_NOT_ACTUAL_MEASUREMENT';
                end
                if isempty(effective)
                    row.error_code = 'requested_interval_not_covered';
                elseif ~isempty(commandError)
                    row.error_code = commandError;
                else
                    row.source_verified = true;
                    if strcmp(field,'load_command')
                        t = command.time_s; force = command.external_force_command_N;
                        torque = command.direct_torque_command_Nm;
                    else
                        t = command.compensation_time_s; force = command.compensation_force_N;
                        torque = command.compensation_direct_torque_Nm;
                    end
                    selected = t>=interval(1) & t<=interval(2);
                    if any(selected)
                        row.status = 'ok'; row.time_range_s = [t(find(selected,1)),t(find(selected,1,'last'))];
                        row.value = struct('available',true,'record_samples',nnz(selected), ...
                            'force_unit','N','force_min_N',min(force(selected)),'force_max_N',max(force(selected)), ...
                            'torque_unit','N*m','direct_torque_min_Nm',min(torque(selected)), ...
                            'direct_torque_max_Nm',max(torque(selected)), ...
                            'independent_measurement',false,'explicit_assumption_required',strcmp(field,'load_compensation'));
                    else
                        row.error_code = 'no_record_samples_in_interval';
                    end
                end
            case 'independent_load'
                row.source_id = 'CTX-PRESCRIBED-1.0';
                row.source_kind = 'absence_in_approved_context';
                row.error_code = 'independent_load_measurement_unavailable';
                row.interpretation_limit = 'ACTUAL_LOAD_REMAINS_UNKNOWN';
            case 'initial_reference'
                row.source_id = 'EMA-OBS-1.0'; row.source_kind = 'absence_in_approved_channel_contract';
                row.error_code = 'independent_initial_reference_unavailable';
                row.interpretation_limit = 'SMALL_RESIDUAL_CANNOT_EXCLUDE_INITIAL_CONSTANT_OFFSET';
            case 'signal_acquisition'
                row.source_id = 'EMA-OBS-1.0'; row.source_kind = 'approved_acquisition_metadata';
                row.independence = 'shared_observation_sources';
                row.interpretation_limit = 'ACQUISITION_METADATA_IS_NOT_HARDWARE_VALIDATION';
                if isempty(effective)
                    row.error_code = 'requested_interval_not_covered';
                else
                    row.status = 'ok'; row.time_range_s = effective;
                    row.value = struct('available',true,'phase_acquisition_state',inspection.preconditions(2).state, ...
                        'dq_currents_independent_of_phase_currents',false, ...
                        'speed_observation_kind','ideal_model_output','physical_sensor_validation',false);
                end
        end
        records = [records;row]; %#ok<AGROW>
        ev = struct('id',row.evidence_id,'quantity',field,'unit','mixed', ...
            'time_range_s',row.time_range_s,'valid',strcmp(row.status,'ok'), ...
            'source_id',row.source_id,'source_kind',row.source_kind);
        evidence = [evidence;ev]; %#ok<AGROW>
    end
    response.status = 'ok';
    if ~any(strcmp({records.status},'ok'))
        response.status = 'insufficient_data'; response.error_code = 'requested_information_unavailable';
    end
    response.result = struct('group_id',inspection.result.group_id,'records',records, ...
        'requested_time_range_s',interval,'effective_time_range_s',effective, ...
        'coverage_complete',complete,'partial_result',any(~strcmp({records.status},'ok')), ...
        'case_input_status',inspection.status);
    response.evidence = evidence;
    if ~complete, response.warnings{end+1} = 'CONTEXT_INTERVAL_PARTIALLY_COVERED'; end
catch issue
    response.status = 'execution_error'; response.error_code = 'internal_execution_error';
    if startsWith(issue.identifier,'Context:')
        response.error_code = extractAfter(issue.identifier,'Context:');
    elseif startsWith(issue.identifier,'Residual:')
        response.error_code = extractAfter(issue.identifier,'Residual:');
    end
    response.result = struct(); response.evidence = [];
end
end

function require(yes,code)
assert(isscalar(yes) && yes,['Context:' code],'Context query failed.');
end
