function response = inspect_case(varargin)
% Agent-facing convenience entry. Its only supported input is a case ID.
if nargin==1
    response = ema_tool('inspect_case',struct('case_id',varargin{1}));
else
    response = ema_tool('inspect_case',struct());
end
end
