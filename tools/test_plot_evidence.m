function report = test_plot_evidence(reportFolder)
% Research-only numerical/graphics checks; never register this entry for Agent.
root = fileparts(fileparts(mfilename('fullpath')));
if nargin==0, reportFolder = fullfile(root,'results','EXP-20261019-009'); end
out = char(java.io.File(reportFolder).getCanonicalPath());
base = char(java.io.File(fullfile(root,'results')).getCanonicalPath());
assert(startsWith(lower(out),lower([base filesep])) && ...
    ~isfile(fullfile(out,'acceptance.json')),'PlotTest:new_report_required','Use a new report folder.');
if ~isfolder(out), mkdir(out); end
release = fullfile(root,'data','agent_visible','observations_v1');
registry = fullfile(root,'tools','registry');
manifest = fullfile(registry,'observations_v1_manifest.json');
derived = fullfile(root,'data','agent_visible','derived_v1');
algorithm = fullfile(registry,'residual_algorithm_v1.json');
before = protectedHashes(root,release,derived);
writeJson(fullfile(out,'protected_hashes_before.json'),before);
catalog = jsondecode(fileread(fullfile(release,'catalog.json')));
checks = struct('name',{},'passed',{}); responses = cell(8,1);
for k = 1:7
    caseId = catalog.cases(k).case_id;
    bundle = compute_residual_bundle(caseId,'prescribed_command');
    response = plot_evidence(bundle.result.bundle_id); responses{k} = response;
    add(['plot_files_' num2str(k)],strcmp(response.status,'ok'));
    folder = fullfile(root,'data','agent_visible','figures_v1',response.result.plot_id);
    png = fullfile(folder,'overview.png'); fig = fullfile(folder,'overview.fig');
    meta = jsondecode(fileread(fullfile(folder,'metadata.json')));
    info = imfinfo(png);
    add(['hashes_and_png_' num2str(k)],info.Width>=1800 && info.Height>=1500 && ...
        strcmp(tool_sha256(png,'file'),response.result.png_sha256) && ...
        strcmp(tool_sha256(fig,'file'),response.result.fig_sha256));
    [r,~] = read_validated_bundle(bundle.result.bundle_id,release,manifest,derived,algorithm);
    [~,~,o] = inspect_case_core(caseId,release,manifest);
    alarms = locate_anomalies(bundle.result.bundle_id);
    f = openfig(fig,'invisible'); cleanup = onCleanup(@() close(f));
    index = unique([1:200:numel(o.time_s),numel(o.time_s)]);
    position = findall(f,'Tag','x_meas_m'); reference = findall(f,'Tag','x_ref_m');
    exact = equalLine(position,o.time_s(index),o.x_meas_m(index)*1000) && ...
        equalLine(reference,o.time_s(index),o.x_ref_m(index)*1000);
    names = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
    scales = [1e6 1 1]; thresholdsAndAlarms = true;
    for j = 1:3
        name = names{j}; values = r.(name)*scales(j); values(~r.motion_valid) = NaN;
        exact = exact && equalLine(findall(f,'Tag',name),r.time_s,values);
        positive = findall(f,'Tag',['threshold_' name]);
        negative = findall(f,'Tag',['threshold_negative_' name]);
        alarm = findall(f,'Tag',['alarm_' name]); channel = alarms.result.channels(j);
        thresholdsAndAlarms = thresholdsAndAlarms && isscalar(positive) && isscalar(negative) && ...
            positive.Value==channel.threshold*scales(j) && negative.Value==-positive.Value;
        if isempty(channel.first_alarm_s)
            thresholdsAndAlarms = thresholdsAndAlarms && isempty(alarm);
        else
            thresholdsAndAlarms = thresholdsAndAlarms && isscalar(alarm) && ...
                alarm.Value==channel.first_alarm_s;
        end
    end
    add(['all_curves_exact_including_validity_' num2str(k)],exact);
    add(['thresholds_and_alarm_times_exact_' num2str(k)],thresholdsAndAlarms);
    labels = findall(f,'Type','text'); strings = string({labels.String});
    safe = safeText(jsonencode(response)) && safeText(jsonencode(meta)) && ...
        safeText(strjoin(strings,'|')) && isequal(f.UserData, ...
        struct('case_id',caseId,'residual_evidence_id',bundle.result.bundle_id,'plot_version','EMA-PLOT-1.0'));
    add(['no_private_labels_or_paths_' num2str(k)],safe);
    clear cleanup;
end
firstBundle = responses{1}.result.residual_evidence_id;
repeat = plot_evidence(firstBundle);
add('repeat_reuses_unchanged_artifacts',strcmp(repeat.status,'ok') && repeat.result.artifact_reused && ...
    strcmp(repeat.result.plot_id,responses{1}.result.plot_id) && ...
    strcmp(repeat.result.png_sha256,responses{1}.result.png_sha256) && ...
    strcmp(repeat.result.fig_sha256,responses{1}.result.fig_sha256));
default = compute_residual_bundle(catalog.cases(1).case_id);
responses{8} = plot_evidence(default.result.bundle_id);
add('default_without_compensation_still_plots',strcmp(responses{8}.status,'ok') && ...
    responses{8}.result.partial_result && strcmp(responses{8}.result.load_assumption,'none'));
f = openfig(fullfile(root,'data','agent_visible','figures_v1',responses{8}.result.plot_id,'overview.fig'),'invisible');
cleanup = onCleanup(@() close(f));
add('missing_compensation_no_fake_waveform_threshold_or_alarm', ...
    isempty(findall(f,'Tag','torque_known_load_Nm')) && ...
    isempty(findall(f,'Tag','threshold_torque_known_load_Nm')) && ...
    isempty(findall(f,'Tag','alarm_torque_known_load_Nm')));
clear cleanup;
bad = plot_evidence('../evaluation_private/data.mat');
add('path_argument_rejected',strcmp(bad.error_code,'invalid_residual_evidence_id'));
bad = ema_tool('plot_evidence',struct('residual_evidence_id',firstBundle,'output_path','other'));
add('arbitrary_output_path_rejected',strcmp(bad.error_code,'invalid_arguments'));
bad = plot_evidence(); add('missing_argument_rejected',strcmp(bad.error_code,'invalid_arguments'));
bad = plot_evidence(['BUNDLE-' repmat('0',1,64)]);
add('unknown_bundle_is_missing_evidence',strcmp(bad.status,'insufficient_data') && ...
    strcmp(bad.error_code,'unknown_residual_evidence'));
% Corrupt a research-side copy, never modify accepted output.
fixture = fullfile(out,'corrupt_plot_fixture'); mkdir(fixture);
source = fullfile(root,'data','agent_visible','figures_v1',responses{1}.result.plot_id);
target = fullfile(fixture,responses{1}.result.plot_id); copyfile(source,target);
h = fopen(fullfile(target,'overview.png'),'a'); fprintf(h,'changed'); fclose(h);
bad = plot_evidence_core(firstBundle,release,manifest,derived,algorithm,registry,fixture);
add('changed_plot_rejected_without_overwrite',strcmp(bad.error_code,'plot_integrity_mismatch'));
% Shared-dispatcher smoke regression: underlying computations are unchanged.
i = inspect_case(catalog.cases(1).case_id);
b = compute_residual_bundle(catalog.cases(1).case_id,'prescribed_command');
a = locate_anomalies(b.result.bundle_id);
c = query_operating_context(catalog.cases(1).case_id);
m = lookup_method_conditions('all',catalog.cases(1).case_id);
add('all_five_existing_tools_still_dispatch',all(strcmp({i.status,b.status,a.status,c.status,m.status},'ok')));
after = protectedHashes(root,release,derived);
add('protected_sources_observations_residuals_models_unchanged',isequal(before,after));
writeJson(fullfile(out,'protected_hashes_after.json'),after);
writeJson(fullfile(out,'case_responses.json'),responses);
report = struct('experiment_id','EXP-20261019-009','passed',all([checks.passed]), ...
    'checks_passed',nnz([checks.passed]),'check_count',numel(checks),'checks',checks, ...
    'formal_overviews',7,'missing_compensation_example',1, ...
    'original_mat_files_verified',59,'public_observation_files_verified',19, ...
    'protected_residual_files',28,'protected_models',2,'new_physical_runs',0,'llm_calls',0);
writeJson(fullfile(out,'acceptance.json'),report);
fprintf('plot_evidence: %d/%d checks passed; 7 case overviews + 1 no-compensation example.\n', ...
    report.checks_passed,report.check_count);
assert(report.passed,'PlotTest:acceptance_failed','Review failed plot checks.');

    function add(name,yes)
        checks(end+1) = struct('name',name,'passed',logical(yes));
    end
end

function yes = equalLine(line,t,y)
yes = isscalar(line) && isequaln(line.XData(:),t(:)) && isequaln(line.YData(:),y(:));
end

function yes = safeText(value)
yes = isempty(regexpi(char(value), ...
    'injected_|appliedFault|evaluation_private|legacy_private|EXP-|(?<![0-9a-z])F[123](?![0-9a-z])|(?<![0-9a-z])[A-Z]:[\\/]','once'));
end

function rows = protectedHashes(root,release,derived)
originals = jsondecode(fileread(fullfile(root,'results','EXP-20261019-003','source_hashes_before.json')));
approved = jsondecode(fileread(fullfile(root,'tools','registry','observations_v1_manifest.json')));
rows = struct('path',{},'sha256',{});
for k = 1:numel(originals)
    path = fullfile(root,originals(k).path); hash = tool_sha256(path,'file');
    assert(strcmpi(hash,originals(k).sha256),'PlotTest:source_changed','Original source changed.');
    rows(end+1) = struct('path',originals(k).path,'sha256',hash); %#ok<AGROW>
end
for k = 1:numel(approved.files)
    file = approved.files(k); hash = tool_sha256(fullfile(release,file.path),'file');
    assert(strcmpi(hash,file.sha256),'PlotTest:public_changed','Approved observation changed.');
    rows(end+1) = struct('path',['data/agent_visible/observations_v1/' file.path],'sha256',hash); %#ok<AGROW>
end
files = [dir(fullfile(derived,'BUNDLE-*','*.mat'));dir(fullfile(derived,'BUNDLE-*','*.json')); ...
    dir(fullfile(root,'matlab','fixed','*.slx'));dir(fullfile(root,'matlab','gradual','*.slx'))];
assert(numel(files)==30,'PlotTest:unexpected_artifacts','Expected 28 residual files and 2 models.');
for k = 1:numel(files)
    path = fullfile(files(k).folder,files(k).name);
    rows(end+1) = struct('path',path(numel(root)+2:end),'sha256',tool_sha256(path,'file')); %#ok<AGROW>
end
end

function writeJson(path,value)
h = fopen(path,'w','n','UTF-8'); assert(h>=0);
cleanup = onCleanup(@() fclose(h)); fprintf(h,'%s',jsonencode(value,'PrettyPrint',true));
end
