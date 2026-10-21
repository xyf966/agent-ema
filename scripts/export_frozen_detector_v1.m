function report = export_frozen_detector_v1()
% Research-only: separate numerical detector settings from labeled legacy MAT.
root = fileparts(fileparts(mfilename('fullpath')));
registry = fullfile(root,'tools','registry');
configPath = fullfile(registry,'detector_thresholds_v1.json');
algorithmPath = fullfile(registry,'detector_algorithm_v1.json');
assert(~isfile(configPath) && ~isfile(algorithmPath),'Paper:ExistingDetector', ...
    'Frozen detector registration must not overwrite an existing version.');
sourcePath = fullfile(root,'data','legacy_private','frozen_detector_source', ...
    '简单检测基线_固定故障结果.mat');
saved = load(sourcePath,'detector'); source = saved.detector;
names = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
units = {'m','A','N*m'};
assert(isequal(source.fields,names) && source.consecutivePoints==10);
assert(all(isfinite(source.threshold)) && all(source.threshold>0));
channels = struct('quantity',{},'unit',{},'threshold',{});
for k = 1:3
    channels(end+1) = struct('quantity',names{k},'unit',units{k}, ...
        'threshold',source.threshold(k)); %#ok<AGROW>
end
config = struct('threshold_version','EMA-DETECTOR-IDEAL-1.0', ...
    'channels',channels,'consecutive_points',10,'sample_interval_s',0.001, ...
    'comparison','strict_absolute_greater_than','invalid_motion_policy','reset_counter', ...
    'calibration_scope','historical_ideal_simulation_baseline', ...
    'noisy_conditions_validated',false);
writeJson(configPath,config);
kernel = fullfile(root,'tools','private','detector_kernel_v1.m');
algorithm = struct('algorithm_version','EMA-ALARM-1.0', ...
    'threshold_version',config.threshold_version, ...
    'thresholds_sha256',paper_file_sha256(configPath), ...
    'kernel_sha256',paper_file_sha256(kernel));
writeJson(algorithmPath,algorithm);
out = fullfile(root,'results','EXP-20261019-007');
if ~isfolder(out), mkdir(out); end
report = struct('source_file','data/legacy_private/frozen_detector_source/简单检测基线_固定故障结果.mat', ...
    'source_sha256',paper_file_sha256(sourcePath),'thresholds',source.threshold, ...
    'thresholds_exported_exactly',true,'algorithm',algorithm);
writeJson(fullfile(out,'detector_export_provenance_private.json'),report);
fprintf('Frozen detector registered: three thresholds, ten consecutive samples.\n');
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8'); assert(handle>=0);
cleanup = onCleanup(@() fclose(handle)); fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
