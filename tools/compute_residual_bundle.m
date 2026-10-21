function response = compute_residual_bundle(varargin)
% Fixed public interface. No source paths or arbitrary parameters are accepted.
if nargin==1
    response = ema_tool('compute_residual_bundle',struct('case_id',varargin{1}));
elseif nargin==2
    response = ema_tool('compute_residual_bundle', ...
        struct('case_id',varargin{1},'load_assumption',varargin{2}));
else
    response = ema_tool('compute_residual_bundle',struct());
end
end
