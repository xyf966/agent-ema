function report = run_step3_f2(resumeSaved)
% Research generation/evaluation entry; never expose this to a diagnosis Agent.
if nargin==0
    resumeSaved = false;
end
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root,'-begin');
state = start_ema_agent_paper("fixed");
experimentId = 'EXP-20261016-003';
folder = fullfile(root,'results',experimentId);
privateFolder = fullfile(root,'data','evaluation_private',experimentId);
if ~resumeSaved
    assert(~isfolder(folder),'Paper:ExistingExperiment','Use a new experiment ID.');
    mkdir(folder); mkdir(privateFolder);
else
    assert(isfile(fullfile(folder,'native_acquisition.mat')), ...
        'Paper:Resume','Saved acquisition is required for resume.');
end
report = struct('experimentId',experimentId,'status','registered', ...
    'startedAt',char(datetime('now','TimeZone','Asia/Shanghai')), ...
    'matlabVersion',version,'simulationExecuted',false, ...
    'independentPhysicalRuns',1,'agentCalls',0, ...
    'modelPath',state.modelPath, ...
    'entryPath',which('paper_run_f2_severity_1500N'), ...
    'tolerance',struct('x_consistency_m',1e-12, ...
    'phase_sum_A',1e-12,'torque_known_load_Nm',1e-8), ...
    'externalForceInportSID','1464', ...
    'externalForceInportInterpolate',get_param( ...
    Simulink.ID.getFullName([state.modelName ':1464']),'Interpolate'), ...
    'fullRuntimeValidationCompleted',false);
if resumeSaved
    report = jsondecode(fileread(fullfile(folder,'run_report.json')));
    if isfield(report,'error')
        if isfield(report,'recoveredPostprocessError')
            report.recoveredPostprocessError = ...
                [report.recoveredPostprocessError newline report.error];
        else
            report.recoveredPostprocessError = report.error;
        end
        report = rmfield(report,'error');
    end
    report.resumedFromSavedData = true;
else
    writeJson(fullfile(folder,'run_report.json'),report);
end
try
    if resumeSaved
        saved = load(fullfile(folder,'residuals.mat'));
        summary = saved.summary;
        residuals = saved.residuals;
        saved = load(fullfile(folder,'observations_aligned.mat'));
        observations = saved.observations;
        saved = load(fullfile(folder,'native_acquisition.mat'));
        acquisition = saved.acquisition;
        saved = load(fullfile(privateFolder,'generation.mat'));
        generation = saved.generation;
    else
    generation = readGeneration(fullfile(root,'matlab','fixed', ...
        'paper_init_unified_ema.m'));
    generation.runId = experimentId;
    generation.condition = 'F2';
    generation.currentBias_A = 1;
    generation.faultStart_s = 0.03;
    generation.externalForceMagnitude_N = 1500;
    save(fullfile(privateFolder,'generation.mat'),'generation');
    summary = table();
    residuals = struct();
    observations = struct();
    acquisition = struct();
    clockStart = tic;
    transcript = evalc(['[summary,residuals,observations,acquisition] = ' ...
        'paper_run_f2_severity_1500N(1);']);
    report.simulationAndResidualWallTime_s = toc(clockStart);
    report.simulationExecuted = true;
    report.compilationPassedThroughSimulation = true;
    writeText(fullfile(folder,'execution.log'),transcript);
    fprintf('%s',transcript);
    save(fullfile(folder,'observations_aligned.mat'),'observations','-v7');
    save(fullfile(folder,'native_acquisition.mat'),'acquisition','-v7.3');
    save(fullfile(folder,'residuals.mat'),'summary','residuals','-v7');
    end
    writetable(summary,fullfile(folder,'summary.csv'));
    writeJson(fullfile(folder,'run_report.json'),report);

    history = load(fullfile(root,'data','legacy_private','2026.10.8', ...
        'F1_F2_F3最小对照_统计与残差数据.mat'),'f2Results');
    previous = history.f2Results{2};
    assert(isequal(residuals.time_s,previous.time_s),'Paper:Time','Time mismatch.');
    assert(isequal(residuals.motion_valid,previous.motion_valid), ...
        'Paper:Motion','Valid motion mask mismatch.');
    frozen = load(fullfile(root,'data','legacy_private', ...
        'frozen_detector_source','简单检测基线_固定故障结果.mat'),'detector');
    fields = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
    assert(isequal(fields,frozen.detector.fields),'Paper:DetectorFields', ...
        'Frozen detector channels differ.');
    difference = zeros(3,1); tolerance = zeros(3,1);
    alarmed = false(3,1); firstAlarm_s = nan(3,1);
    validMaxAbs = zeros(3,1); aboveThresholdPoints = zeros(3,1);
    for j = 1:3
        difference(j) = max(abs(residuals.(fields{j})-previous.(fields{j})));
        tolerance(j) = report.tolerance.(fields{j});
        detection = paper_ema_simple_detector(residuals,fields{j}, ...
            frozen.detector.threshold(j),frozen.detector.consecutivePoints);
        alarmed(j) = detection.alarmed;
        firstAlarm_s(j) = detection.firstAlarm_s;
        aboveThresholdPoints(j) = detection.aboveThresholdPoints;
        validMaxAbs(j) = max(abs(residuals.(fields{j})(residuals.motion_valid)));
    end
    comparison = table(string(fields(:)),difference,tolerance, ...
        difference<=tolerance,'VariableNames', ...
        {'Residual','MaxAbsoluteDifference','Tolerance','Passed'});
    alarms = table(string(fields(:)),validMaxAbs,frozen.detector.threshold(:), ...
        alarmed,firstAlarm_s,aboveThresholdPoints,'VariableNames', ...
        {'Residual','ValidMaxAbs','Threshold','Alarmed', ...
        'FirstAlarm_s','AboveThresholdPoints'});
    writetable(comparison,fullfile(folder,'historical_comparison.csv'));
    writetable(alarms,fullfile(folder,'alarms.csv'));
    loadCheck = inspectLoad(acquisition,observations);
    writeJson(fullfile(folder,'load_interpolation_check.json'),loadCheck);
    report.migrationComparisonPassed = all(comparison.Passed);
    report.expectedMainChannelPatternMatched = ~alarmed(1) && alarmed(2);
    report.firstCurrentAlarm_s = firstAlarm_s(2);
    report.torqueAlarmed = alarmed(3);
    report.firstTorqueAlarm_s = firstAlarm_s(3);
    report.residualOutputPoints = numel(residuals.time_s);
    report.validMotionPoints = nnz(residuals.motion_valid);
    report.modelDirtyAfterRun = get_param(state.modelName,'Dirty');
    report.loadCheck = loadCheck;
    evaluation = struct('faultStart_s',generation.faultStart_s, ...
        'currentBias_A',generation.currentBias_A, ...
        'alarmDelay_s',firstAlarm_s(2)-generation.faultStart_s);
    save(fullfile(privateFolder,'evaluation.mat'),'evaluation');
    healthy = load(fullfile(root,'results','EXP-20261016-001','residuals.mat'), ...
        'summary');
    crossResponse = table(summary.Direction,healthy.summary.TorqueRMS_Nm, ...
        summary.TorqueRMS_Nm, ...
        summary.TorqueRMS_Nm./healthy.summary.TorqueRMS_Nm, ...
        'VariableNames',{'Direction','HealthyTorqueRMS_Nm', ...
        'F2TorqueRMS_Nm','RMSRatio'});
    crossResponse.WindowMaxAbs_Nm = zeros(2,1);
    crossResponse.AboveThresholdPoints = zeros(2,1);
    for directionIndex = 1:2
        mask = residuals.time_s>=0.05+0.5*(directionIndex-1) & ...
            residuals.time_s<=0.18+0.5*(directionIndex-1) & residuals.motion_valid;
        values = abs(residuals.torque_known_load_Nm(mask));
        crossResponse.WindowMaxAbs_Nm(directionIndex) = max(values);
        crossResponse.AboveThresholdPoints(directionIndex) = ...
            nnz(values>frozen.detector.threshold(3));
    end
    writetable(crossResponse,fullfile(folder,'torque_cross_response.csv'));
    nativeExternalForce = acquisition.nativeSignals.get( ...
        'external_force_known_N').Values;
    externalForceInput = acquisition.externalInput.get('ExternalForce');
    save(fullfile(folder,'F2电流偏置1A_复现结果.mat'), ...
        'experimentId','summary','residuals','observations','alarms', ...
        'comparison','crossResponse','loadCheck', ...
        'nativeExternalForce','externalForceInput','-v7');
    plot_step3_f2(folder,root,observations,residuals, ...
        acquisition,frozen.detector.threshold,firstAlarm_s);
    report.status = 'completed_with_differences';
    if report.migrationComparisonPassed && report.expectedMainChannelPatternMatched
        report.status = 'f2_replay_passed';
    end
    report.completedAt = char(datetime('now','TimeZone','Asia/Shanghai'));
    writeJson(fullfile(folder,'run_report.json'),report);
    disp(comparison); disp(alarms); disp(crossResponse); disp(loadCheck);
catch runError
    report.status = 'failed';
    report.error = getReport(runError,'extended','hyperlinks','off');
    writeJson(fullfile(folder,'run_report.json'),report);
    rethrow(runError);
end
end

function generation = readGeneration(initializer)
run(initializer);
generation.nominal = ema;
end

function check = inspectLoad(acquisition,d)
native = acquisition.nativeSignals.get('external_force_known_N').Values;
input = acquisition.externalInput.get('ExternalForce');
[time,index] = unique(native.Time(:),'last');
value = native.Data(index);
inputTime = input.Time(:);
inputValue = input.Data(:);
linear = interp1(inputTime,inputValue,time,'linear');
step = interp1(inputTime,inputValue,time,'previous');
check.nativeSamples = numel(time);
check.nativeIntermediateForcePoints = nnz(abs(value)>1e-6 & abs(value)<1500-1e-6);
check.nativeMaxDifferenceFromLinearInput_N = max(abs(value-linear));
check.nativeMaxDifferenceFromStepInput_N = max(abs(value-step));
check.nativeMatchesLinearInput = check.nativeMaxDifferenceFromLinearInput_N<1e-6;
check.nativeMatchesStepInput = check.nativeMaxDifferenceFromStepInput_N<1e-6;
check.alignedMaxDifferenceFromLinearInput_N = max(abs( ...
    d.external_force_known_N-interp1(inputTime,inputValue,d.time_s,'linear')));
stable = (d.time_s>=0.05 & d.time_s<=0.18) | ...
    (d.time_s>=0.55 & d.time_s<=0.68);
check.stableWindowMaxDifferenceFromStepInput_N = max(abs( ...
    d.external_force_known_N(stable)- ...
    interp1(inputTime,inputValue,d.time_s(stable),'previous')));
if check.nativeIntermediateForcePoints>0 && check.nativeMatchesLinearInput
    check.conclusion = 'Native routed force already has linear transitions; not created solely by postprocessing alignment.';
elseif check.nativeMatchesStepInput
    check.conclusion = 'Native sampled force is step-valued; inspect native time density before attributing aligned ramps to plant interpolation.';
else
    check.conclusion = 'Native force differs from both reference interpolations; further investigation required.';
end
end

function writeJson(path,value)
writeText(path,jsonencode(value,'PrettyPrint',true));
end

function writeText(path,value)
handle = fopen(path,'w','n','UTF-8');
assert(handle>=0,'Paper:Write','Cannot save experiment record.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',value);
end
