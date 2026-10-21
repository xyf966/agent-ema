function response = locate_anomalies_core(id,interval,release,manifest,derived,residualAlgorithm,registry)
response = struct('tool','locate_anomalies','tool_version','EMA-LOCATE-1.0', ...
    'case_id','','status','execution_error','error_code','', ...
    'input_hash','','parameter_version','','model_hash','', ...
    'threshold_version','EMA-DETECTOR-IDEAL-1.0','detector_hash','', ...
    'preconditions',[],'result',struct(),'evidence',[], ...
    'warnings',{{}},'duration_ms',0);
try
    descriptor = jsondecode(fileread(fullfile(registry,'detector_algorithm_v1.json')));
    configPath = fullfile(registry,'detector_thresholds_v1.json');
    configHash = tool_sha256(configPath,'file');
    kernel = fullfile(fileparts(mfilename('fullpath')),'detector_kernel_v1.m');
    kernelHash = tool_sha256(kernel,'file');
    require(strcmp(descriptor.algorithm_version,'EMA-ALARM-1.0') && ...
        strcmp(descriptor.threshold_version,response.threshold_version) && ...
        strcmp(descriptor.thresholds_sha256,configHash) && ...
        strcmp(descriptor.kernel_sha256,kernelHash),'detector_integrity_mismatch');
    config = jsondecode(fileread(configPath)); validateConfig(config);
    [residuals,parent] = read_validated_bundle(id,release,manifest,derived,residualAlgorithm);
    response.case_id = parent.case_id;
    response.parameter_version = parent.parameter_version;
    response.preconditions = parent.preconditions;
    response.warnings = parent.warnings;
    response.warnings{end+1} = 'THRESHOLDS_FOR_IDEAL_HISTORICAL_REPLAY_ONLY';
    response.detector_hash = kernelHash;
    [channels,calls,scope] = analyze_anomalies_v1(residuals,parent.result.channels,config,interval);
    response.input_hash = tool_sha256(strjoin({'EMA-LOCATE-1.0',id, ...
        parent.result.artifact_sha256,configHash,kernelHash,jsonencode(scope.requested_interval_s)},'|'),'text');
    response.status = 'ok';
    if calls==0
        response.status = 'insufficient_data'; response.error_code = 'no_detectable_channel_in_interval';
    end
    anyAlarm = false;
    for k = 1:numel(channels)
        ev = ['ANOM-' response.input_hash '-' num2str(k)];
        if channels(k).detector_executed
            anyAlarm = anyAlarm || channels(k).alarmed;
            entry = struct('id',ev,'quantity',channels(k).quantity, ...
                'unit',channels(k).unit,'time_range_s',scope.effective_interval_s, ...
                'valid',true,'parent_evidence_id',channels(k).parent_evidence_id, ...
                'interpretation_basis',channels(k).interpretation_basis);
            response.evidence = [response.evidence;entry];
        end
    end
    scopeEvidence = ['ANOM-' response.input_hash '-scope'];
    response.evidence = [response.evidence;struct('id',scopeEvidence, ...
        'quantity','analysis_interval_validity','unit','s', ...
        'time_range_s',scope.effective_interval_s,'valid',scope.longest_valid_run_points>=10, ...
        'parent_evidence_id',parent.result.input_inspection_evidence_id, ...
        'interpretation_basis','valid_motion_mask_and_requested_interval')];
    if calls==0, anyAlarm = []; end
    response.result = struct('residual_evidence_id',id,'threshold_version',response.threshold_version, ...
        'consecutive_points',10,'sample_interval_s',0.001, ...
        'channels',channels,'detector_call_count',calls,'any_alarm',anyAlarm, ...
        'partial_result',any(~strcmp({channels.status},'ok')),'analysis_scope',scope, ...
        'independent_load_supported',false,'residual_evidence_verified_without_writing',true);
    response.preconditions(end+1) = struct('name','selected_interval_persistence_support', ...
        'state',stateOf(scope.longest_valid_run_points>=10), ...
        'evidence_id',scopeEvidence);
    if ~scope.coverage_complete
        response.warnings{end+1} = 'ANALYSIS_INTERVAL_PARTIALLY_COVERED';
    end
catch issue
    response.status = 'execution_error'; response.error_code = 'internal_execution_error';
    if startsWith(issue.identifier,'Anomaly:')
        response.error_code = extractAfter(issue.identifier,'Anomaly:');
        if ismember(response.error_code,{'unknown_residual_evidence','residual_source_unavailable'})
            response.status = 'insufficient_data';
        elseif strcmp(response.error_code,'unsupported_residual_sample_rate')
            response.status = 'not_applicable';
        end
    end
    response.result = struct(); response.evidence = [];
end
end

function validateConfig(c)
require(hasKeys(c,{'threshold_version','channels','consecutive_points','sample_interval_s', ...
    'comparison','invalid_motion_policy','calibration_scope','noisy_conditions_validated'}) && ...
    strcmp(c.threshold_version,'EMA-DETECTOR-IDEAL-1.0') && c.consecutive_points==10 && ...
    c.sample_interval_s==0.001 && strcmp(c.comparison,'strict_absolute_greater_than') && ...
    strcmp(c.invalid_motion_policy,'reset_counter') && ...
    strcmp(c.calibration_scope,'historical_ideal_simulation_baseline') && ...
    isequal(c.noisy_conditions_validated,false),'invalid_detector_config');
fields = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
units = {'m','A','N*m'};
require(isstruct(c.channels) && numel(c.channels)==3,'invalid_detector_config');
for k = 1:3
    ch = c.channels(k);
    require(hasKeys(ch,{'quantity','unit','threshold'}) && strcmp(ch.quantity,fields{k}) && ...
        strcmp(ch.unit,units{k}) && isa(ch.threshold,'double') && isscalar(ch.threshold) && ...
        isfinite(ch.threshold) && ch.threshold>0,'invalid_detector_config');
end
end

function yes = hasKeys(value,names)
yes = isstruct(value) && isscalar(value) && ...
    isequal(sort(string(fieldnames(value))),sort(string(names(:))));
end

function state = stateOf(yes)
state = 'violated'; if yes, state = 'satisfied'; end
end

function require(yes,code)
assert(isscalar(yes) && yes,['Anomaly:' code],'Anomaly tool check failed.');
end
