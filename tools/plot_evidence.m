function response = plot_evidence(varargin)
% Plot an approved residual bundle; no path, label, or code arguments.
if nargin==1
    response = ema_tool('plot_evidence',struct('residual_evidence_id',varargin{1}));
else
    response = ema_tool('plot_evidence',struct());
end
end
