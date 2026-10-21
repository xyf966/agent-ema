function report = run_step1_healthy()
% Research-side migration replay only; this is not an Agent-facing tool.
root = fileparts(fileparts(mfilename('fullpath')));
addpath(root,'-begin');
state = start_ema_agent_paper("fixed");
experimentId = 'EXP-20261016-001';
resultFolder = fullfile(root,'results',experimentId);
privateFolder = fullfile(root,'data','evaluation_private',experimentId);
assert(~isfolder(resultFolder),'Paper:ExistingExperiment', ...
    'This experiment already exists; use a new ID for a new physical run.');
mkdir(resultFolder);
mkdir(privateFolder);
diary(fullfile(resultFolder,'execution.log'));
diaryCleanup = onCleanup(@() diary('off'));
report = struct('experimentId',experimentId,'status','started', ...
    'startedAt',char(datetime('now','TimeZone','Asia/Shanghai')), ...
    'matlabVersion',version,'simulationExecuted',false, ...
    'migrationComparisonPassed',false,'agentExperiment',false);
writeReport(resultFolder,report);
try
    report.products = ver;
    report.modelPath = state.modelPath;
    report.entryPath = which('paper_run_healthy_external_load');
    report.residualPath = which('paper_ema_diagnostic_residuals');
    report.initializerPath = which('paper_init_unified_ema');
    report.solver = get_param(state.modelName,'Solver');
    report.solverType = get_param(state.modelName,'SolverType');
    report.fixedStep = get_param(state.modelName,'FixedStep');
    % Declared before simulation; thresholds remain those of historical replay.
    report.comparisonTolerance = struct('x_consistency_m',1e-12, ...
        'phase_sum_A',1e-12,'torque_known_load_Nm',1e-8);
    report.loadContext = ['Prescribed ideal bench load: commanded external ' ...
        'force, checked through its routed model signal. No independent load ' ...
        'sensor is asserted. This assumption applies to this replay only.'];
    writeReport(resultFolder,report);
    generation = readGeneration(fullfile(root,'matlab','fixed', ...
        'paper_init_unified_ema.m'));
    generation.externalForceMagnitude_N = 1500;
    generation.runId = experimentId;
    generation.condition = 'healthy';
    save(fullfile(privateFolder,'generation.mat'),'generation');
    clockStart = tic;
    [summary,residuals,observations] = paper_run_healthy_external_load(1500);
    report.simulationAndResidualWallTime_s = toc(clockStart);
    report.simulationExecuted = true;
    report.compilationPassedThroughSimulation = true;
    save(fullfile(resultFolder,'observations_aligned.mat'),'observations','-v7');
    save(fullfile(resultFolder,'residuals.mat'),'summary','residuals','-v7');
    writetable(summary,fullfile(resultFolder,'summary.csv'));
    writeReport(resultFolder,report);

    historyPath = fullfile(root,'data','legacy_private','2026.10.8', ...
        'F1_F2_F3最小对照_统计与残差数据.mat');
    history = load(historyPath,'summary','results');
    previous = history.results{2};
    assert(isequal(residuals.time_s,previous.time_s), ...
        'Paper:ReplayTime','Historical residual time grid differs.');
    assert(isequal(residuals.motion_valid,previous.motion_valid), ...
        'Paper:ReplayMotion','Historical validity mask differs.');
    fields = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
    differences = zeros(3,1);
    tolerances = zeros(3,1);
    validMax = zeros(3,1);
    alarmed = false(3,1);
    firstAlarm_s = nan(3,1);
    aboveThresholdPoints = zeros(3,1);
    detectorPath = fullfile(root,'data','legacy_private', ...
        'frozen_detector_source','简单检测基线_固定故障结果.mat');
    frozen = load(detectorPath,'detector');
    for j = 1:3
        differences(j) = max(abs(residuals.(fields{j})-previous.(fields{j})));
        tolerances(j) = report.comparisonTolerance.(fields{j});
        validMax(j) = max(abs(residuals.(fields{j})(residuals.motion_valid)));
        detection = paper_ema_simple_detector(residuals,fields{j}, ...
            frozen.detector.threshold(j),frozen.detector.consecutivePoints);
        alarmed(j) = detection.alarmed;
        firstAlarm_s(j) = detection.firstAlarm_s;
        aboveThresholdPoints(j) = detection.aboveThresholdPoints;
    end
    comparison = table(string(fields(:)),differences,tolerances, ...
        differences<=tolerances,'VariableNames', ...
        {'Residual','MaxAbsoluteDifference','Tolerance','Passed'});
    alarms = table(string(fields(:)),validMax,frozen.detector.threshold(:), ...
        alarmed,firstAlarm_s,aboveThresholdPoints,'VariableNames', ...
        {'Residual','ValidMaxAbs','Threshold','Alarmed', ...
        'FirstAlarm_s','AboveThresholdPoints'});
    historicalSummary = history.summary(history.summary.Force_N==1500,:);
    save(fullfile(resultFolder,'replay_comparison.mat'), ...
        'comparison','alarms','historicalSummary');
    writetable(comparison,fullfile(resultFolder,'historical_comparison.csv'));
    writetable(alarms,fullfile(resultFolder,'alarms.csv'));
    report.historyPath = historyPath;
    report.detectorSourcePath = detectorPath;
    report.alignedObservationSamples = numel(observations.time_s);
    report.residualOutputPoints = numel(residuals.time_s);
    report.validMotionPoints = nnz(residuals.motion_valid);
    report.migrationComparisonPassed = all(comparison.Passed);
    report.anyAlarm = any(alarmed);
    report.modelDirtyAfterRun = get_param(state.modelName,'Dirty');
    report.observationsAreAligned = true;
    report.agentVisibleExportCompleted = false;
    report.fullFixedAndGradualValidationCompleted = false;
    disp(comparison);
    disp(alarms);
    plot_healthy_replay(resultFolder,observations,residuals,frozen.detector.threshold);
    if all(comparison.Passed) && ~any(alarmed)
        report.status = 'healthy_replay_passed';
    else
        report.status = 'completed_with_differences';
    end
    report.completedAt = char(datetime('now','TimeZone','Asia/Shanghai'));
    writeReport(resultFolder,report);
catch runError
    report.status = 'failed';
    report.error = getReport(runError,'extended','hyperlinks','off');
    writeReport(resultFolder,report);
    rethrow(runError);
end
end

function generation = readGeneration(initializer)
run(initializer);
generation.nominal = ema;
end

function writeReport(folder,report)
handle = fopen(fullfile(folder,'run_report.json'),'w','n','UTF-8');
assert(handle>=0,'Paper:Report','Cannot write experiment report.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(report,'PrettyPrint',true));
end

