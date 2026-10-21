function report = generate_stage4_boundary(kind)
% Research generation only. Never expose this entry or its outputs to Agent.
kind = validatestring(kind,{'initial_offset','load_mismatch'});
root = fileparts(fileparts(mfilename('fullpath')));
state = start_ema_agent_paper("fixed");
if strcmp(kind,'initial_offset')
    experiment = 'EXP-20261020-016'; forceMagnitude = 1500; bias = 0.02e-3;
else
    experiment = 'EXP-20261020-017'; forceMagnitude = 1800; bias = 0;
end
folder = fullfile(root,'results',experiment);
private = fullfile(root,'data','evaluation_private',experiment);
assert(~isfolder(folder) && ~isfolder(private),'Paper:ExistingRun', ...
    'Preserve existing runs; resume postprocessing from saved observations.');
mkdir(folder); mkdir(private);
generation = struct('experiment_id',experiment,'research_case',kind, ...
    'normal_force_magnitude_N',forceMagnitude,'position_bias_m',bias, ...
    'bias_start_s',0,'diagnostic_force_assumption_N',1500, ...
    'position_reference_independent',false,'load_measurement_independent',false);
parameters = readParameters(fullfile(root,'matlab','fixed','paper_init_unified_ema.m'));
nominal = parameters.ema;
assert(nominal.fault.activeMode==0 && ~nominal.fault.position.enabled && ...
    ~nominal.fault.current.enabled && ~nominal.fault.mechanical.enabled, ...
    'Paper:HealthySeed','Require healthy nominal configuration.');
if bias~=0
    parameters.ema.fault.activeMode = 1;
    parameters.ema.fault.position.enabled = true;
    parameters.ema.fault.position.bias_m = bias;
    parameters.ema.fault.position.startTime_s = 0;
end
generation.nominal = nominal;
generation.applied_parameters = parameters;
generation.source_model_sha256 = paper_file_sha256(state.modelPath);
generation.source_entry_sha256 = paper_file_sha256(mfilename('fullpath') + ".m");
save(fullfile(private,'generation.mat'),'generation','-v7');
report = struct('experiment_id',experiment,'user_stage',4,'step',2, ...
    'status','registered','simulation_attempts',0,'simulation_completed',false, ...
    'matlab_version',version,'model_path',state.modelPath, ...
    'model_sha256_before',generation.source_model_sha256, ...
    'started_at',char(datetime('now','TimeZone','Asia/Shanghai')), ...
    'llm_calls',0,'independent_physical_runs',1);
writeJson(fullfile(folder,'run_report.json'),report);
try
    % SIDs discovered from the actual local model; all are read/log overrides.
    sids = [1588 1598 1601 1538 1538 1597 1580 1602];
    ports = [1 1 1 4 7 1 1 1];
    names = {'x_meas_m','omega_meas_radps','iabc_meas_A','id_meas_A', ...
        'iq_meas_A','external_force_known_N','x_ref_m','private_position_true_m'};
    logging = Simulink.Simulation.LoggingSpecification();
    for j = 1:numel(sids)
        block = Simulink.ID.getFullName(sprintf('%s:%d',state.modelName,sids(j)));
        signal = Simulink.SimulationData.SignalLoggingInfo(block,ports(j));
        signal.LoggingInfo.NameMode = true;
        signal.LoggingInfo.LoggingName = names{j};
        signal.LoggingInfo.DecimateData = false;
        signal.LoggingInfo.LimitDataPoints = false;
        logging.addSignalsToLog(signal);
    end
    t = (0:0.001:0.8)';
    force = zeros(size(t));
    force(t>=0.02 & t<0.19) = forceMagnitude;
    force(t>=0.52 & t<0.69) = -forceMagnitude;
    reference = 0.005*(min(t/0.2,1)-min(max((t-0.5)/0.2,0),1));
    values = {zeros(size(t)),zeros(size(t)),force,reference};
    inputNames = {'OmegaRef','LoadTorque','ExternalForce','PositionRef'};
    inputSids = [1443 1444 1464 1478];
    dataset = Simulink.SimulationData.Dataset;
    for j = 1:4
        block = Simulink.ID.getFullName(sprintf('%s:%d',state.modelName,inputSids(j)));
        assert(str2double(get_param(block,'Port'))==j && ...
            strcmp(get_param(block,'Name'),inputNames{j}),'Paper:InputOrder', ...
            'Dataset index must match root Inport number.');
        ts = timeseries(values{j},t);
        if j==3, ts.DataInfo.Interpolation = tsdata.interpolation('zoh'); end
        dataset = dataset.addElement(ts,inputNames{j});
    end
    in = Simulink.SimulationInput(state.modelName);
    parameterNames = fieldnames(parameters);
    for j = 1:numel(parameterNames)
        in = in.setVariable(parameterNames{j},parameters.(parameterNames{j}));
    end
    in = in.setExternalInput(dataset);
    in = in.setModelParameter('StopTime','0.8','SaveOutput','off', ...
        'SignalLogging','on','SignalLoggingName','logsout');
    in = in.setLoggingSpecification(logging);
    save(fullfile(private,'simulation_input.mat'),'in','-v7.3');
    report.simulation_attempts = 1; report.status = 'simulating';
    writeJson(fullfile(folder,'run_report.json'),report);
    timer = tic;
    transcript = evalc('out = sim(in);');
    report.simulation_wall_time_s = toc(timer);
    report.simulation_completed = true; report.compilation_passed_through_simulation = true;
    report.status = 'simulation_completed';
    writeText(fullfile(folder,'execution.log'),transcript);
    disp(out.logsout.getElementNames);
    acquisition = struct('nativeSignals',out.logsout,'externalInput',dataset, ...
        'simulationMetadata',out.SimulationMetadata);
    save(fullfile(private,'native_acquisition.mat'),'acquisition','-v7.3');
    d = struct('time_s',(0:5e-6:0.8)');
    for j = 1:7
        ts = out.logsout.get(names{j}).Values;
        [time,index] = unique(ts.Time(:),'last');
        data = reshape(ts.Data,numel(ts.Time),[]);
        assert(time(1)<=0 && time(end)>=0.8,'Paper:Coverage','Incomplete native log.');
        d.(names{j}) = interp1(time,data(index,:),d.time_s,'linear');
    end
    d.loadKnown = true;
    d.direct_torque_known_Nm = zeros(size(d.time_s));
    observations = d;
    save(fullfile(folder,'observations_aligned.mat'),'observations','-v7');
    ts = out.logsout.get('private_position_true_m').Values;
    [time,index] = unique(ts.Time(:),'last');
    data = reshape(ts.Data,numel(ts.Time),[]);
    evaluation = struct('position_true_m',interp1(time,data(index,:),d.time_s,'linear'));
    evaluation.actual_bias_m = d.x_meas_m-evaluation.position_true_m;
    evaluation.max_bias_error_m = max(abs(evaluation.actual_bias_m-bias));
    evaluation.initial_bias_m = evaluation.actual_bias_m(1);
    assert(evaluation.max_bias_error_m<1e-12,'Paper:BiasNotApplied', ...
        'Measured minus private true position must equal configured bias from t=0.');
    save(fullfile(private,'evaluation.mat'),'evaluation','-v7');
    report.initial_bias_m = evaluation.initial_bias_m;
    report.max_bias_error_m = evaluation.max_bias_error_m;
    report.model_sha256_after = paper_file_sha256(state.modelPath);
    assert(strcmp(report.model_sha256_before,report.model_sha256_after), ...
        'Paper:ModelChanged','Model bytes changed.');
    report.status = 'observations_saved';
    report.completed_at = char(datetime('now','TimeZone','Asia/Shanghai'));
    writeJson(fullfile(folder,'run_report.json'),report);
catch issue
    report.status = 'failed'; report.error_identifier = issue.identifier;
    report.error = getReport(issue,'extended','hyperlinks','off');
    writeJson(fullfile(folder,'run_report.json'),report);
    rethrow(issue);
end
end

function parameters = readParameters(initializer)
run(initializer);
variables = whos;
parameters = struct();
for j = 1:numel(variables)
    name = variables(j).name;
    if ~strcmp(name,'initializer'), parameters.(name) = eval(name); end
end
end

function writeJson(path,value)
writeText(path,jsonencode(value,'PrettyPrint',true));
end

function writeText(path,value)
handle = fopen(path,'w','n','UTF-8');
assert(handle>=0,'Paper:Write','Cannot write output.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',value);
end
