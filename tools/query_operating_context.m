function response = query_operating_context(varargin)
% Case ID, optional field list, optional time range; no caller-selected paths.
if nargin>=1 && nargin<=3
    payload = struct('case_id',varargin{1});
    if nargin>=2
        fields = varargin{2};
        if ischar(fields), fields = {fields}; end
        payload.fields = fields;
    end
    if nargin==3, payload.time_range_s = varargin{3}; end
    response = ema_tool('query_operating_context',payload);
else
    response = ema_tool('query_operating_context',struct());
end
end
