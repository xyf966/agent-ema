function [channels,calls,scope] = analyze_anomalies_v1(r,sourceChannels,config,interval)
% Pure scoped analysis: only this function invokes the frozen detector kernel.
require(isfield(r,'time_s') && isa(r.time_s,'double') && iscolumn(r.time_s) && ...
    ~isempty(r.time_s) && all(isfinite(r.time_s)) && all(diff(r.time_s)>0),'invalid_residual_time');
t = r.time_s;
require(isfield(r,'motion_valid') && islogical(r.motion_valid) && ...
    isequal(size(r.motion_valid),size(t)),'invalid_motion_mask');
if numel(t)>1
    require(max(abs(diff(t)-0.001))<1e-10,'unsupported_residual_sample_rate');
end
if isempty(interval), interval = [t(1),t(end)]; end
require(isa(interval,'double') && numel(interval)==2 && isreal(interval) && ...
    all(isfinite(interval)) && interval(1)<=interval(2),'invalid_analysis_interval');
index = find(t>=interval(1) & t<=interval(2));
effective = []; validIntervals = zeros(0,2); longestValid = 0;
if ~isempty(index)
    effective = [t(index(1)),t(index(end))];
    valid = r.motion_valid(index);
    [first,last] = runs(valid);
    if ~isempty(first)
        validIntervals = [t(index(first)),t(index(last))];
        longestValid = max(last-first+1);
    end
else
    valid = false(0,1);
end
scope = struct('requested_interval_s',interval(:)', ...
    'effective_interval_s',effective,'sample_count',numel(index), ...
    'valid_motion_intervals_s',validIntervals,'longest_valid_run_points',longestValid, ...
    'counter_reset_at_interval_start',true, ...
    'coverage_complete',interval(1)>=t(1) && interval(2)<=t(end));
channels = struct([]); calls = 0;
for k = 1:3
    field = config.channels(k).quantity;
    threshold = config.channels(k).threshold;
    source = sourceChannels(strcmp({sourceChannels.quantity},field));
    require(isscalar(source),'missing_channel_state');
    row = struct('quantity',field,'unit',config.channels(k).unit,'threshold',threshold, ...
        'status',source.status,'error_code',source.error_code,'alarmed',[], ...
        'first_exceed_s',[],'first_alarm_s',[],'valid_points',0,'above_threshold_points',0, ...
        'detector_executed',false,'exceedance_segments',struct([]), ...
        'alarm_intervals_s',zeros(0,2),'parent_evidence_id',source.evidence_id, ...
        'interpretation_basis',source.interpretation_basis);
    if ~strcmp(row.status,'ok')
        channels = [channels;row]; %#ok<AGROW>
        continue;
    end
    row.status = 'insufficient_data';
    if ~isfield(r,field)
        row.error_code = 'residual_channel_unavailable';
    elseif isempty(index)
        row.error_code = 'analysis_interval_without_samples';
    else
        values = r.(field);
        require(isa(values,'double') && isreal(values) && iscolumn(values) && ...
            numel(values)==numel(t),'invalid_residual_shape');
        values = values(index);
        row.valid_points = nnz(valid);
        if any(~isfinite(values))
            row.error_code = 'nonfinite_residual_data';
        else
            above = valid & abs(values)>threshold;
            row.above_threshold_points = nnz(above);
            firstExceed = find(above,1);
            if ~isempty(firstExceed), row.first_exceed_s = t(index(firstExceed)); end
            [first,last] = runs(above);
            for j = 1:numel(first)
                count = last(j)-first(j)+1;
                confirmation = [];
                if count>=config.consecutive_points
                    confirmation = t(index(first(j)+config.consecutive_points-1));
                    row.alarm_intervals_s(end+1,:) = [confirmation,t(index(last(j)))];
                end
                segment = struct('start_s',t(index(first(j))),'end_s',t(index(last(j))), ...
                    'points',count,'persistence_satisfied',count>=config.consecutive_points, ...
                    'confirmed_at_s',confirmation);
                row.exceedance_segments = [row.exceedance_segments;segment];
            end
            if longestValid<config.consecutive_points
                row.error_code = 'insufficient_contiguous_valid_points';
            else
                input = struct('time_s',t(index),'motion_valid',valid);
                input.(field) = values;
                found = detector_kernel_v1(input,field,threshold,config.consecutive_points);
                calls = calls+1;
                row.detector_executed = true; row.status = 'ok'; row.error_code = '';
                row.alarmed = found.alarmed;
                if found.alarmed, row.first_alarm_s = found.firstAlarm_s; end
                require(found.validPoints==row.valid_points && ...
                    found.aboveThresholdPoints==row.above_threshold_points,'detector_count_mismatch');
                if ~isempty(row.alarm_intervals_s)
                    require(found.alarmed && found.firstAlarm_s==row.alarm_intervals_s(1,1), ...
                        'detector_interval_mismatch');
                else
                    require(~found.alarmed,'detector_interval_mismatch');
                end
            end
        end
    end
    channels = [channels;row]; %#ok<AGROW>
end
end

function [first,last] = runs(mask)
first = find(diff([false;mask(:)])==1);
last = find(diff([mask(:);false])==-1);
end

function require(yes,code)
assert(isscalar(yes) && yes,['Anomaly:' code],'Scoped detection check failed.');
end
