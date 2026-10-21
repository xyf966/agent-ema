function result = detector_kernel_v1(residuals, fieldName, threshold, consecutivePoints)
% Baseline detector: absolute residual above a healthy threshold for K points.
% Only motion_valid points count; an invalid point resets the counter.
validateattributes(threshold,{'numeric'}, ...
    {'scalar','real','finite','positive'},mfilename,'threshold');
validateattributes(consecutivePoints,{'numeric'}, ...
    {'scalar','integer','positive'},mfilename,'consecutivePoints');
assert(isfield(residuals,fieldName),'Diagnosis:ResidualField', ...
    'Requested residual field is missing.');
t = residuals.time_s(:);
signal = residuals.(fieldName);
signal = signal(:);
valid = logical(residuals.motion_valid(:));
assert(numel(t)==numel(signal) && numel(t)==numel(valid) && ...
    all(isfinite(t)) && all(isfinite(signal)) && all(diff(t)>0), ...
    'Diagnosis:DetectorInput','Residual, time, and validity must align.');
assert(abs(median(diff(t))-0.001)<1e-10, ...
    'Diagnosis:DetectorRate','Detector expects 1 ms residual output.');

above = valid & abs(signal)>threshold;
count = 0;
firstIndex = NaN;
for j = 1:numel(t)
    if above(j)
        count = count+1;
    else
        count = 0;
    end
    if count>=consecutivePoints
        firstIndex = j;
        break
    end
end
result.alarmed = isfinite(firstIndex);
result.firstAlarm_s = NaN;
if result.alarmed
    result.firstAlarm_s = t(firstIndex);
end
result.validPoints = nnz(valid);
result.aboveThresholdPoints = nnz(above);
end
