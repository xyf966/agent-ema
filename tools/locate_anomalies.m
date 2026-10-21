function response = locate_anomalies(varargin)
% Public convenience entry. Only opaque bundle IDs and an optional interval.
if nargin==1
    response = ema_tool('locate_anomalies',struct('residual_evidence_id',varargin{1}));
elseif nargin==2
    response = ema_tool('locate_anomalies',struct('residual_evidence_id',varargin{1}, ...
        'analysis_interval_s',varargin{2}));
else
    response = ema_tool('locate_anomalies',struct());
end
end
