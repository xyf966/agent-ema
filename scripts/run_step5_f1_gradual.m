function report = run_step5_f1_gradual(resumeSaved)
% Research-side replay. Config, injection and scoring stay in private storage.
if nargin==0
    resumeSaved = false;
end
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root,'-begin');
state = start_ema_agent_paper("gradual");
experimentId = 'EXP-20261016-005';
folder = fullfile(root,'results',experimentId);
privateFolder = fullfile(root,'data','evaluation_private',experimentId);
if ~resumeSaved
    assert(~isfolder(folder),'Paper:ExistingExperiment','Use a new experiment ID.');
    mkdir(folder); mkdir(privateFolder);
    report = struct('experimentId',experimentId,'status','registered', ...
        'startedAt',char(datetime('now','TimeZone','Asia/Shanghai')), ...
        'matlabVersion',version,'modelPath',state.modelPath, ...
        'entryPath',which('paper_run_f1_gradual_1500N'), ...
        'residualPath',which('paper_ema_diagnostic_residuals'), ...
        'independentPhysicalRuns',1,'agentCalls',0,'simulationExecuted',false, ...
        'tolerance',struct('x_consistency_m',1e-12,'phase_sum_A',1e-12, ...
        'torque_known_load_Nm',1e-8),'fullRuntimeValidationCompleted',false);
    writeJson(fullfile(folder,'run_report.json'),report);
    planned = struct('fault','F1','faultStart_s',0.03,'faultEnd_s',0.18, ...
        'finalBias_mm',0.02,'rampDuration_s',0.15,'externalForce_N',1500, ...
        'stopTime_s',0.8);
    save(fullfile(privateFolder,'planned_generation.mat'),'planned');
else
    report = jsondecode(fileread(fullfile(folder,'run_report.json')));
    report.resumedFromSavedData = true;
end
try
    if ~resumeSaved
        alarmTable = table(); result = struct(); config = struct();
        observations = struct(); acquisition = struct(); evaluation = struct();
        clockStart = tic;
        transcript = evalc(['[alarmTable,result,config,observations,' ...
            'acquisition,evaluation] = paper_run_f1_gradual_1500N();']);
        report.simulationAndResidualWallTime_s = toc(clockStart);
        report.simulationExecuted = true;
        report.compilationPassedThroughSimulation = true;
        writeText(fullfile(folder,'execution.log'),transcript);
        fprintf('%s',transcript);
        save(fullfile(privateFolder,'generation_and_evaluation.mat'), ...
            'config','evaluation','alarmTable','result','-v7');
        save(fullfile(folder,'observations_aligned.mat'),'observations','-v7');
        save(fullfile(folder,'native_acquisition.mat'),'acquisition','-v7.3');
    else
        saved = load(fullfile(privateFolder,'generation_and_evaluation.mat'));
        config = saved.config; evaluation = saved.evaluation;
        alarmTable = saved.alarmTable; result = saved.result;
        saved = load(fullfile(folder,'observations_aligned.mat'));
        observations = saved.observations;
        saved = load(fullfile(folder,'native_acquisition.mat'));
        acquisition = saved.acquisition;
    end
    % Explicit researcher-side separation, not a registered Agent case exporter.
    residualFields = {'time_s','window_s','x_consistency_m','phase_sum_A', ...
        'iq_mean_A','iq_rms_A','tracking_error_m','omega_mean_radps', ...
        'torque_uncompensated_Nm','torque_known_load_Nm','motion_valid'};
    residuals = struct();
    for j = 1:numel(residualFields)
        residuals.(residualFields{j}) = result.(residualFields{j});
    end
    assert(~any(startsWith(fieldnames(observations),'injected_')));
    assert(~any(startsWith(acquisition.nativeSignals.getElementNames,'injected_')));
    alarms = alarmTable(:,{'Residual','Threshold','MaxAbsValid','Alarmed', ...
        'FirstExceed_s','FirstAlarm_s'});
    history = load(fullfile(root,'data','legacy_private','2026.10.13', ...
        'F1代表性渐变_1500N.mat'));
    previous = history.f1GradualResult;
    assert(isequal(residuals.time_s,previous.time_s),'Paper:Time','Time mismatch.');
    assert(isequal(residuals.motion_valid,previous.motion_valid), ...
        'Paper:Motion','Valid-motion mask mismatch.');
    fields = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
    difference = zeros(3,1); tolerance = zeros(3,1);
    redetectedAlarm = false(3,1); redetectedTime = nan(3,1);
    frozen = load(fullfile(root,'data','legacy_private','frozen_detector_source', ...
        '简单检测基线_固定故障结果.mat'),'detector');
    assert(isequal(config.detector,frozen.detector),'Paper:ThresholdDrift', ...
        'The detector must remain frozen.');
    for j = 1:3
        difference(j) = max(abs(residuals.(fields{j})-previous.(fields{j})));
        tolerance(j) = report.tolerance.(fields{j});
        detection = paper_ema_simple_detector(residuals,fields{j}, ...
            frozen.detector.threshold(j),frozen.detector.consecutivePoints);
        redetectedAlarm(j) = detection.alarmed;
        redetectedTime(j) = detection.firstAlarm_s;
    end
    assert(isequal(redetectedAlarm,alarms.Alarmed) && ...
        isequaln(redetectedTime,alarms.FirstAlarm_s), ...
        'Paper:Separation','Detection changed after removing truth fields.');
    comparison = table(string(fields(:)),difference,tolerance, ...
        difference<=tolerance,'VariableNames', ...
        {'Residual','MaxAbsoluteDifference','Tolerance','Passed'});
    summary = table();
    for directionIndex = 1:2
        mask = residuals.time_s>=0.05+0.5*(directionIndex-1) & ...
            residuals.time_s<=0.18+0.5*(directionIndex-1) & residuals.motion_valid;
        row = table(directionIndex,nnz(mask), ...
            max(abs(residuals.x_consistency_m(mask)))*1e6, ...
            mean(residuals.phase_sum_A(mask)), ...
            mean(residuals.torque_known_load_Nm(mask)), ...
            sqrt(mean(residuals.torque_known_load_Nm(mask).^2)), ...
            'VariableNames',{'Direction','Samples','PositionResidualMax_um', ...
            'PhaseSumMean_A','TorqueMean_Nm','TorqueRMS_Nm'});
        summary = [summary;row]; %#ok<AGROW>
    end
    evaluation.historicalAlarmTableIdentical = ...
        isequaln(alarmTable,history.f1GradualAlarmTable);
    evaluation.historicalProfileMaxDifference_m = ...
        max(abs(result.injected_bias_m-previous.injected_bias_m));
    evaluation.profileMaxError_m = config.profileMaxError_m;
    save(fullfile(privateFolder,'evaluation_checks.mat'),'evaluation');
    report.migrationComparisonPassed = all(comparison.Passed);
    report.historicalAlarmTableIdentical = evaluation.historicalAlarmTableIdentical;
    report.profileMaxError_m = config.profileMaxError_m;
    report.firstPositionAlarm_s = alarms.FirstAlarm_s(1);
    report.expectedAlarmPatternMatched = isequal(alarms.Alarmed,[true;false;false]);
    report.noPreFaultAlarms = ~any(alarmTable.PreFaultAlarm);
    report.detectorUnchangedAfterTruthRemoval = true;
    report.nativeObservedSignalCount = acquisition.nativeSignals.numElements;
    report.residualOutputPoints = numel(residuals.time_s);
    report.validMotionPoints = nnz(residuals.motion_valid);
    report.modelDirtyAfterRun = get_param(state.modelName,'Dirty');
    report.agentVisibleExportCompleted = false;
    save(fullfile(folder,'residuals.mat'),'residuals','summary','alarms','-v7');
    save(fullfile(folder,'F1代表性渐变_复现结果.mat'), ...
        'experimentId','summary','observations','residuals','alarms','comparison','-v7');
    writetable(alarms,fullfile(folder,'alarms.csv'));
    writetable(summary,fullfile(folder,'summary.csv'));
    writetable(comparison,fullfile(folder,'historical_comparison.csv'));
    plot_step5_f1_gradual(folder,observations,residuals,alarms,evaluation);
    report.status = 'completed_with_differences';
    if report.migrationComparisonPassed && report.expectedAlarmPatternMatched && ...
            report.historicalAlarmTableIdentical && report.noPreFaultAlarms && ...
            config.profileMaxError_m<1e-10
        report.status = 'f1_gradual_replay_passed';
    end
    report.completedAt = char(datetime('now','TimeZone','Asia/Shanghai'));
    writeJson(fullfile(folder,'run_report.json'),report);
    disp(alarms); disp(comparison); disp(summary);
    fprintf('Injection QA error: %.12g m; bias at first alarm: %.12g um\n', ...
        config.profileMaxError_m,alarmTable.BiasAtAlarm_um(1));
catch runError
    report.status = 'failed';
    report.error = getReport(runError,'extended','hyperlinks','off');
    writeJson(fullfile(folder,'run_report.json'),report);
    rethrow(runError);
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
