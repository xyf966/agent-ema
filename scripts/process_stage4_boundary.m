function report = process_stage4_boundary(kind)
% Research-only postprocessing of saved observations. Never re-runs sim().
kind = validatestring(kind,{'initial_offset','load_mismatch'});
root = fileparts(fileparts(mfilename('fullpath')));
start_ema_agent_paper("fixed");
if strcmp(kind,'initial_offset'), experiment = 'EXP-20261020-016';
else, experiment = 'EXP-20261020-017'; end
folder = fullfile(root,'results',experiment);
private = fullfile(root,'data','evaluation_private',experiment);
assert(~isfile(fullfile(folder,'postprocess_report.json')),'Paper:ExistingPostprocess', ...
    'Preserve completed postprocessing evidence.');
saved = load(fullfile(folder,'observations_aligned.mat'),'observations');
generation = load(fullfile(private,'generation.mat'),'generation');
d = saved.observations;
nominal = generation.generation.nominal;
policy = jsondecode(fileread(fullfile(root,'configs','observation_export_v1.json')));
approved = select_public_observations(d,policy);
assert(numel(approved.time_s)==160001,'Paper:Length','Unexpected input scope.');
correctResiduals = paper_ema_diagnostic_residuals(d,nominal);
assumption = struct('time_s',(0:0.001:0.8)', ...
    'force_magnitude_N',1500,'source_kind','recorded_diagnostic_assumption', ...
    'independent_measurement',false);
assumption.external_force_N = zeros(size(assumption.time_s));
assumption.external_force_N(assumption.time_s>=0.02 & assumption.time_s<0.19) = 1500;
assumption.external_force_N(assumption.time_s>=0.52 & assumption.time_s<0.69) = -1500;
assumed = d;
assumed.external_force_known_N = interp1(assumption.time_s,assumption.external_force_N,d.time_s,'linear');
residuals = paper_ema_diagnostic_residuals(assumed,nominal);
save(fullfile(folder,'residuals.mat'),'residuals','correctResiduals','assumption','-v7');
frozen = jsondecode(fileread(fullfile(root,'tools/registry/detector_thresholds_v1.json')));
fields = {frozen.channels.quantity};
alarmTemplate = struct('quantity','','alarmed',false,'first_alarm_s',[], ...
    'valid_points',0,'above_threshold_points',0,'valid_max_abs',0);
diagnosticAlarm = repmat(alarmTemplate,1,3); correctAlarm = diagnosticAlarm;
for j=1:3
    a = paper_ema_simple_detector(residuals,fields{j},frozen.channels(j).threshold,10);
    b = paper_ema_simple_detector(correctResiduals,fields{j},frozen.channels(j).threshold,10);
    diagnosticAlarm(j) = makeAlarm(fields{j},a,residuals);
    correctAlarm(j) = makeAlarm(fields{j},b,correctResiduals);
end
if strcmp(kind,'initial_offset')
    history = load(fullfile(root,'data/legacy_private/2026.10.9', ...
        'F1启动已有偏置0.02mm_健康与运行中注入对照.mat'),'f1InitialResults');
    previous = history.f1InitialResults{2};
else
    history = load(fullfile(root,'data/legacy_private/2026.10.9', ...
        '正常外载1800N与1500N加F3阻力300N_混淆对照.mat'),'healthy1800Result');
    previous = history.healthy1800Result;
end
assert(isequal(correctResiduals.time_s,previous.time_s) && ...
    isequal(correctResiduals.motion_valid,previous.motion_valid), ...
    'Paper:ReplayGrid','Historical residual grid or validity differs.');
comparisons = repmat(struct('quantity','','max_absolute_difference',0,'exactly_equal',false),1,3);
for j=1:3
    delta = max(abs(correctResiduals.(fields{j})-previous.(fields{j})));
    comparisons(j) = struct('quantity',fields{j},'max_absolute_difference',delta, ...
        'exactly_equal',isequal(correctResiduals.(fields{j}),previous.(fields{j})));
end
writeJson(fullfile(folder,'historical_comparison.json'),comparisons);
% Formula: residual(assumed) - residual(correct) = average(c*(actual-assumed)).
t = d.time_s; dt = median(diff(t));
last = (round(0.010/dt)+1:round(0.001/dt):numel(t))';
first = last-round(0.010/dt);
c = nominal.mechanics.screwLead_mPerRev/(2*pi*nominal.mechanics.gearRatio*nominal.mechanics.efficiency);
integ = cumtrapz(t,c*(d.external_force_known_N-assumed.external_force_known_N));
predicted = (integ(last)-integ(first))./(t(last)-t(first));
formulaError = max(abs(residuals.torque_known_load_Nm-correctResiduals.torque_known_load_Nm-predicted));
assert(formulaError<1e-10,'Paper:CompensationFormula','Compensation difference formula failed.');
if strcmp(kind,'initial_offset')
    assert(~any([diagnosticAlarm.alarmed]),'Paper:UnexpectedBoundaryAlarm', ...
        'Initial-offset boundary must be evaluated explicitly if alarms differ.');
    withoutBias = d;
    withoutBias.x_meas_m = d.x_meas_m-generation.generation.position_bias_m;
    offsetRemoved = paper_ema_diagnostic_residuals(withoutBias,nominal);
    blindspotError = max(abs(correctResiduals.x_consistency_m-offsetRemoved.x_consistency_m));
    assert(blindspotError<1e-12,'Paper:OffsetCancellation','Constant offset cancellation failed.');
    extra = struct('constant_offset_cancellation_error_m',blindspotError);
else
    assert(~any([correctAlarm.alarmed]) && ~diagnosticAlarm(1).alarmed && ...
        ~diagnosticAlarm(2).alarmed && diagnosticAlarm(3).alarmed, ...
        'Paper:LoadBoundaryAlarm','Load compensation boundary response differs.');
    f3 = load(fullfile(root,'results/EXP-20261016-004/residuals.mat'),'residuals');
    stable = [0.05 0.18;0.55 0.68];
    means = zeros(2,3); gaps = zeros(2,1);
    for k=1:2
        mask = residuals.time_s>=stable(k,1) & residuals.time_s<=stable(k,2) & residuals.motion_valid;
        assert(all(f3.residuals.motion_valid(mask)),'Paper:F3Scope','F3 reference interval invalid.');
        means(k,:) = [mean(correctResiduals.torque_known_load_Nm(mask)), ...
            mean(residuals.torque_known_load_Nm(mask)),mean(f3.residuals.torque_known_load_Nm(mask))];
        gaps(k) = max(abs(residuals.torque_known_load_Nm(mask)-f3.residuals.torque_known_load_Nm(mask)));
    end
    extra = struct('stable_intervals_s',stable,'mean_columns', ...
        {{'healthy_correct_command','healthy_recorded_assumption','F3_reference'}}, ...
        'stable_torque_means_Nm',means,'max_assumed_vs_F3_difference_Nm',gaps);
end
acq = load(fullfile(private,'native_acquisition.mat'),'acquisition');
command = acq.acquisition.externalInput.getElement('ExternalForce');
alignedCommand = interp1(command.Time,command.Data,d.time_s,'linear');
commandAlignmentError = max(abs(alignedCommand-d.external_force_known_N));
assert(commandAlignmentError<1e-9,'Paper:CommandAlignment','Command replay mismatch.');
report = struct('experiment_id',experiment,'status','passed', ...
    'new_simulations_in_postprocess',0,'sample_count',numel(d.time_s), ...
    'time_range_s',[d.time_s(1),d.time_s(end)],'sample_interval_s',dt, ...
    'valid_motion_intervals_s',validIntervals(residuals), ...
    'diagnostic_assumption_alarms',diagnosticAlarm,'correct_command_alarms',correctAlarm, ...
    'historical_comparisons',comparisons, ...
    'all_three_historical_residuals_exactly_equal',all([comparisons.exactly_equal]), ...
    'compensation_difference_formula_error_Nm',formulaError, ...
    'command_alignment_max_error_N',commandAlignmentError,'additional_checks',extra);
writeJson(fullfile(folder,'postprocess_report.json'),report);
disp(report);
end

function a = makeAlarm(field,detection,r)
time = []; if detection.alarmed, time = detection.firstAlarm_s; end
a = struct('quantity',field,'alarmed',detection.alarmed,'first_alarm_s',time, ...
    'valid_points',detection.validPoints,'above_threshold_points',detection.aboveThresholdPoints, ...
    'valid_max_abs',max(abs(r.(field)(r.motion_valid))));
end

function intervals = validIntervals(r)
first = find(diff([false;r.motion_valid(:)])==1);
last = find(diff([r.motion_valid(:);false])==-1);
intervals = [r.time_s(first),r.time_s(last)];
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8');
assert(handle>=0,'Paper:Write','Cannot write output.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
