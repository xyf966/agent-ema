function report = test_locate_anomalies(reportFolder)
% Research acceptance: historical tables, controlled negative data, pure rule tests.
root = fileparts(fileparts(mfilename('fullpath')));
if nargin==0, reportFolder = fullfile(root,'results','EXP-20261019-007'); end
out = char(java.io.File(reportFolder).getCanonicalPath());
base = char(java.io.File(fullfile(root,'results')).getCanonicalPath());
require(startsWith(lower(out),lower([base filesep])),'output_root');
require(~isfile(fullfile(out,'acceptance.json')),'existing_report');
if ~isfolder(out), mkdir(out); end
registry = fullfile(root,'tools','registry');
release = fullfile(root,'data','agent_visible','observations_v1');
derived = fullfile(root,'data','agent_visible','derived_v1');
manifest = fullfile(registry,'observations_v1_manifest.json');
algorithm = fullfile(registry,'residual_algorithm_v1.json');
private = fullfile(root,'data','evaluation_private','EXP-20261019-007');
if ~isfolder(private), mkdir(private); end
mapping = jsondecode(fileread(fullfile(root,'data','evaluation_private', ...
    'EXP-20261019-004','case_mapping.json')));
config = jsondecode(fileread(fullfile(registry,'detector_thresholds_v1.json')));
legacy = load(fullfile(root,'data','legacy_private','frozen_detector_source', ...
    '简单检测基线_固定故障结果.mat'),'detector');
checks = struct('name',{},'passed',{},'status',{},'error_code',{});
comparisons = struct('case_id',{},'source_run_id',{},'quantity',{}, ...
    'alarmed',{},'first_exceed_s',{},'first_alarm_s',{},'reference_first_alarm_s',{}, ...
    'first_alarm_time_difference_s',{},'time_tolerance_s',{},'above_threshold_points',{},'passed',{});
responses = cell(7,2);
before = snapshot(derived);
for k = 1:7
    bundle = compute_residual_bundle(mapping(k).case_id,'prescribed_command');
    value = locate_anomalies(bundle.result.bundle_id);
    responses{k,1} = value; assertSafe(value);
    reference = load(fullfile(root,'results',mapping(k).source_run_id,'residuals.mat'),'residuals');
    alarms = readtable(fullfile(root,'results',mapping(k).source_run_id,'alarms.csv'));
    for j = 1:3
        row = value.result.channels(j); field = config.channels(j).quantity;
        selected = reference.residuals.motion_valid & ...
            abs(reference.residuals.(field))>legacy.detector.threshold(j);
        firstIndex = find(selected,1); firstExceed = [];
        if ~isempty(firstIndex), firstExceed = reference.residuals.time_s(firstIndex); end
        firstAlarm = alarms.FirstAlarm_s(j);
        if isnan(firstAlarm), firstAlarm = []; end
        passed = strcmp(row.status,'ok') && row.alarmed==logical(alarms.Alarmed(j)) && ...
            sameTime(row.first_alarm_s,firstAlarm) && isequal(row.first_exceed_s,firstExceed) && ...
            row.above_threshold_points==nnz(selected) && row.threshold==legacy.detector.threshold(j);
        comparisons(end+1) = struct('case_id',mapping(k).case_id, ...
            'source_run_id',mapping(k).source_run_id,'quantity',field,'alarmed',row.alarmed, ...
            'first_exceed_s',row.first_exceed_s,'first_alarm_s',row.first_alarm_s, ...
            'reference_first_alarm_s',firstAlarm, ...
            'first_alarm_time_difference_s',timeDifference(row.first_alarm_s,firstAlarm), ...
            'time_tolerance_s',1e-12, ...
            'above_threshold_points',row.above_threshold_points,'passed',passed); %#ok<AGROW>
        checks(end+1) = item(['historical_' num2str(k) '_' num2str(j)],passed,value); %#ok<AGROW>
    end
    plain = compute_residual_bundle(mapping(k).case_id);
    value = locate_anomalies(plain.result.bundle_id);
    responses{k,2} = value; assertSafe(value);
    checks(end+1) = item(['default_skip_compensation_' num2str(k)], ...
        strcmp(value.status,'ok') && value.result.detector_call_count==2 && ...
        strcmp(value.result.channels(3).status,'insufficient_data') && ...
        ~value.result.channels(3).detector_executed && isempty(value.result.channels(3).alarmed),value); %#ok<AGROW>
end
id = responses{1,1}.result.residual_evidence_id;
repeat = locate_anomalies(id);
checks(end+1) = item('stable_same_scope_evidence', ...
    isequal(rmfield(repeat,'duration_ms'),rmfield(responses{1,1},'duration_ms')),repeat);
short = locate_anomalies(id,[0.035,0.040]);
checks(end+1) = item('short_registered_interval_is_insufficient', ...
    strcmp(short.status,'insufficient_data') && short.result.detector_call_count==0 && ...
    isempty(short.result.any_alarm),short);
scoped = locate_anomalies(id,[0.035,0.050]);
checks(end+1) = item('registered_interval_resets_counter', ...
    strcmp(scoped.status,'ok') && sameTime(scoped.result.channels(2).first_alarm_s,0.044),scoped);
bad = locate_anomalies('../evaluation_private/hidden.mat');
checks(end+1) = expected('path_id_rejected',bad,'execution_error','invalid_residual_evidence_id');
bad = ema_tool('locate_anomalies',struct('residual_evidence_id',id,'threshold',1));
checks(end+1) = expected('arbitrary_threshold_rejected',bad,'execution_error','invalid_arguments');
bad = ema_tool('locate_anomalies',struct('residual_evidence_id',id,'threshold_version','other'));
checks(end+1) = expected('unfrozen_version_rejected',bad,'execution_error','invalid_threshold_version');
bad = locate_anomalies(id,[0.2,0.1]);
checks(end+1) = expected('reversed_interval_rejected',bad,'execution_error','invalid_analysis_interval');
bad = locate_anomalies(id,[NaN,0.1]);
checks(end+1) = expected('nonfinite_interval_rejected',bad,'execution_error','invalid_analysis_interval');
bad = locate_anomalies(['BUNDLE-' repmat('0',1,64)]);
checks(end+1) = expected('unknown_bundle_reported',bad,'insufficient_data','unknown_residual_evidence');
[syntheticChecks,syntheticCount] = pureChecks(config);
checks = [checks,syntheticChecks];
fixed = fileread(fullfile(root,'matlab','fixed','paper_ema_simple_detector.m'));
gradual = fileread(fullfile(root,'matlab','gradual','paper_ema_simple_detector.m'));
kernel = strrep(fileread(fullfile(root,'tools','private','detector_kernel_v1.m')), ...
    'function result = detector_kernel_v1(residuals, fieldName, threshold, consecutivePoints)', ...
    'function result = paper_ema_simple_detector(residuals, fieldName, threshold, consecutivePoints)');
checks(end+1) = item('detector_body_matches_both_sources',strcmp(fixed,gradual) && strcmp(fixed,kernel),repeat);
token = char(java.util.UUID.randomUUID());
copied = fullfile(private,['derived_' token]);
[ok,message] = copyfile(derived,copied); assert(ok,'%s',message);
matFile = fullfile(copied,id,'residuals.mat');
metaFile = fullfile(copied,id,'metadata.json');
s = load(matFile); residuals = s.residuals; residuals.x_consistency_m(1) = 1;
save(matFile,'residuals','-v7');
bad = locate_anomalies_core(id,[],release,manifest,copied,algorithm,registry);
checks(end+1) = expected('tampered_artifact_rejected',bad,'execution_error','evidence_integrity_mismatch');
meta = jsondecode(fileread(metaFile)); meta.artifact_sha256 = tool_sha256(matFile,'file');
writeJson(metaFile,meta);
bad = locate_anomalies_core(id,[],release,manifest,copied,algorithm,registry);
checks(end+1) = expected('forged_checksum_rejected_by_recalculation',bad,'execution_error','residual_validation_failed');
fixtureRegistry = fullfile(private,['registry_' token]);
[ok,message] = copyfile(registry,fixtureRegistry); assert(ok,'%s',message);
c = jsondecode(fileread(fullfile(fixtureRegistry,'detector_thresholds_v1.json')));
c.channels(1).threshold = c.channels(1).threshold*2;
writeJson(fullfile(fixtureRegistry,'detector_thresholds_v1.json'),c);
bad = locate_anomalies_core(id,[],release,manifest,derived,algorithm,fixtureRegistry);
checks(end+1) = expected('changed_threshold_file_rejected',bad,'execution_error','detector_integrity_mismatch');
% A trusted private fixture supplies reconstructed acquisition metadata.
fixtureRelease = fullfile(private,['release_' token]);
[ok,message] = copyfile(release,fixtureRelease); assert(ok,'%s',message);
fixtureManifest = fullfile(private,['manifest_' token '.json']);
c = jsondecode(fileread(fullfile(fixtureRelease,'channel_contract.json')));
c.phase_acquisition = 'third_phase_reconstructed';
writeJson(fullfile(fixtureRelease,'channel_contract.json'),c);
m = jsondecode(fileread(manifest));
for j = 1:numel(m.files), m.files(j).sha256 = tool_sha256(fullfile(fixtureRelease,m.files(j).path),'file'); end
writeJson(fixtureManifest,m);
fixtureDerived = fullfile(private,['phase_evidence_' token]);
produced = compute_residual_core(mapping(1).case_id,'none',fixtureRelease,fixtureManifest,fixtureDerived,algorithm);
phase = locate_anomalies_core(produced.result.bundle_id,[],fixtureRelease,fixtureManifest,fixtureDerived,algorithm,registry);
checks(end+1) = item('reconstructed_phase_never_sent_to_detector', ...
    strcmp(phase.status,'ok') && phase.result.detector_call_count==1 && ...
    strcmp(phase.result.channels(2).status,'not_applicable') && ...
    ~phase.result.channels(2).detector_executed && isempty(phase.result.channels(2).alarmed),phase);
checks(end+1) = item('derived_inputs_unchanged',isequal(before,snapshot(derived)),repeat);
files = {'ema_tool.m','locate_anomalies.m','private/locate_anomalies_core.m', ...
    'private/read_validated_bundle.m','private/analyze_anomalies_v1.m', ...
    'private/detector_kernel_v1.m','private/compute_residual_core.m','test_locate_anomalies.m'};
lint = struct('file',{},'message_count',{},'messages',{});
for k = 1:numel(files)
    issues = checkcode(fullfile(root,'tools',files{k}),'-id');
    lint(end+1) = struct('file',files{k},'message_count',numel(issues),'messages',issues); %#ok<AGROW>
end
report = struct('experiment_id','EXP-20261019-007','stage',2,'step',3,'substep',3, ...
    'passed',all([checks.passed]) && all([comparisons.passed]) && all([lint.message_count]==0), ...
    'case_count',7,'new_physical_runs',0,'llm_agent_calls',0, ...
    'pure_rule_scenarios',syntheticCount,'checks',checks,'historical_comparisons',comparisons, ...
    'code_analyzer',lint,'completed_at',char(datetime('now','TimeZone','Asia/Shanghai')));
writeJson(fullfile(out,'acceptance.json'),report);
writeJson(fullfile(out,'case_responses.json'),responses);
require(report.passed,'acceptance_failed');
fprintf('locate_anomalies: %d/%d checks; %d historical channel comparisons passed.\n', ...
    nnz([checks.passed]),numel(checks),numel(comparisons));
end

function [checks,count] = pureChecks(config)
names = {'ten_points','nine_points','below_threshold_reset','invalid_motion_reset', ...
    'strict_threshold','negative_residual','nonfinite_channel','no_motion','short_interval', ...
    'interval_counter_reset','two_segments','outside_interval','wrong_sample_rate'};
checks = struct('name',{},'passed',{},'status',{},'error_code',{});
source = struct('quantity',{},'status',{},'error_code',{},'evidence_id',{},'interpretation_basis',{});
for k = 1:3
    source(end+1) = struct('quantity',config.channels(k).quantity,'status','ok', ...
        'error_code','','evidence_id',['TEST-' num2str(k)],'interpretation_basis','synthetic_rule_check'); %#ok<AGROW>
end
for k = 1:numel(names)
    r = struct('time_s',(0:0.001:0.029)','motion_valid',true(30,1), ...
        'x_consistency_m',zeros(30,1),'phase_sum_A',zeros(30,1),'torque_known_load_Nm',zeros(30,1));
    threshold = config.channels(1).threshold;
    r.x_consistency_m(:) = 2*threshold; interval = [];
    switch names{k}
        case 'nine_points', r.x_consistency_m(10:end) = 0;
        case 'below_threshold_reset', r.x_consistency_m(10) = 0;
        case 'invalid_motion_reset', r.motion_valid(10) = false;
        case 'strict_threshold', r.x_consistency_m(:) = threshold;
        case 'negative_residual', r.x_consistency_m(:) = -2*threshold;
        case 'nonfinite_channel', r.x_consistency_m(1) = NaN;
        case 'no_motion', r.motion_valid(:) = false;
        case 'short_interval', interval = [0,0.008];
        case 'interval_counter_reset', interval = [0.005,0.020];
        case 'two_segments', r.x_consistency_m(11:20) = 0;
        case 'outside_interval', interval = [0.05,0.07];
        case 'wrong_sample_rate', r.time_s = r.time_s*10;
    end
    if strcmp(names{k},'wrong_sample_rate')
        identifier = '';
        try
            analyze_anomalies_v1(r,source,config,interval);
        catch issue
            identifier = issue.identifier;
        end
        passed = strcmp(identifier,'Anomaly:unsupported_residual_sample_rate');
    else
        [channels,calls] = analyze_anomalies_v1(r,source,config,interval);
        c = channels(1);
        switch names{k}
            case {'ten_points','negative_residual'}
                passed = c.alarmed && c.first_alarm_s==r.time_s(10) && c.first_exceed_s==r.time_s(1) && calls==3;
            case 'nine_points', passed = ~c.alarmed && c.above_threshold_points==9;
            case {'below_threshold_reset','invalid_motion_reset'}
                passed = c.alarmed && c.first_alarm_s==r.time_s(20) && numel(c.exceedance_segments)==2;
            case 'strict_threshold', passed = ~c.alarmed && c.above_threshold_points==0;
            case 'nonfinite_channel'
                passed = strcmp(c.status,'insufficient_data') && ~c.detector_executed && calls==2;
            case {'no_motion','short_interval','outside_interval'}
                passed = strcmp(c.status,'insufficient_data') && calls==0 && isempty(c.alarmed);
            case 'interval_counter_reset', passed = c.alarmed && c.first_alarm_s==r.time_s(15);
            case 'two_segments'
                expected = [r.time_s(10),r.time_s(10);r.time_s(30),r.time_s(30)];
                passed = c.alarmed && isequal(c.alarm_intervals_s,expected);
        end
    end
    checks(end+1) = struct('name',['rule_' names{k}],'passed',passed, ...
        'status','rule_test','error_code',''); %#ok<AGROW>
end
count = numel(names);
end

function files = snapshot(root)
listing = dir(fullfile(root,'**','*')); listing = listing(~[listing.isdir]);
files = struct('path',{},'sha256',{});
for k = 1:numel(listing)
    path = fullfile(listing(k).folder,listing(k).name);
    files(end+1) = struct('path',path(numel(root)+2:end),'sha256',tool_sha256(path,'file')); %#ok<AGROW>
end
end

function value = expected(name,response,status,code)
assertSafe(response);
value = item(name,strcmp(response.status,status) && strcmp(response.error_code,code),response);
end

function value = item(name,passed,response)
assertSafe(response);
value = struct('name',name,'passed',passed,'status',response.status,'error_code',response.error_code);
end

function assertSafe(value)
blocked = '(?i)(EXP-\d{8}|(?<![a-z0-9])F[123](?![a-z0-9])|healthy|gradual|injected_|evaluation_private|legacy_private|(?<![a-z])[a-z]:[\\/]|secret)';
require(isempty(regexp(jsonencode(value),blocked,'once')),'response_leak');
end

function require(yes,code)
assert(isscalar(yes) && yes,['AnomalyTest:' code],'Anomaly acceptance failed.');
end

function yes = sameTime(a,b)
yes = (isempty(a) && isempty(b)) || ...
    (isscalar(a) && isscalar(b) && abs(a-b)<=1e-12);
end

function difference = timeDifference(a,b)
if isempty(a) && isempty(b)
    difference = 0;
elseif isscalar(a) && isscalar(b)
    difference = abs(a-b);
else
    difference = Inf;
end
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8'); assert(handle>=0);
cleanup = onCleanup(@() fclose(handle)); fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
