function response = lookup_method_conditions(varargin)
% Fixed generic methods, optionally assessed against approved case metadata.
if nargin==1 || nargin==2
    payload = struct('method_id',varargin{1});
    if nargin==2, payload.case_id = varargin{2}; end
    response = ema_tool('lookup_method_conditions',payload);
else
    response = ema_tool('lookup_method_conditions',struct());
end
end
