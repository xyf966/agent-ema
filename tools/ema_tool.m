function response = ema_tool(varargin)
% Registered dispatcher: no arbitrary paths, function names, or MATLAB code.
started = tic;
response = emptyResponse();
if nargin~=2 || ~isTextScalar(varargin{1}) || ...
        ~ismember(char(varargin{1}),{'inspect_case','compute_residual_bundle','locate_anomalies', ...
        'query_operating_context','lookup_method_conditions','plot_evidence'})
    response.tool = ''; response.tool_version = '';
    response.error_code = 'unsupported_tool_or_call';
    response.duration_ms = 1000*toc(started);
    return;
end
tool = char(varargin{1});
response.tool = tool;
if strcmp(tool,'compute_residual_bundle'), response.tool_version = 'EMA-RESIDUAL-1.0'; end
payload = varargin{2};
folder = fileparts(mfilename('fullpath'));
if strcmp(tool,'plot_evidence')
    response.tool_version = 'EMA-PLOT-1.0';
    if ~isstruct(payload) || ~isscalar(payload) || ...
            ~isequal(fieldnames(payload),{'residual_evidence_id'}) || ...
            ~isTextScalar(payload.residual_evidence_id)
        response.error_code = 'invalid_arguments';
    elseif isempty(regexp(char(payload.residual_evidence_id),'^BUNDLE-[0-9a-f]{64}$','once'))
        response.error_code = 'invalid_residual_evidence_id';
    else
        root = fileparts(folder);
        response = plot_evidence_core(char(payload.residual_evidence_id), ...
            fullfile(root,'data','agent_visible','observations_v1'), ...
            fullfile(folder,'registry','observations_v1_manifest.json'), ...
            fullfile(root,'data','agent_visible','derived_v1'), ...
            fullfile(folder,'registry','residual_algorithm_v1.json'), ...
            fullfile(folder,'registry'),fullfile(root,'data','agent_visible','figures_v1'));
    end
    response.duration_ms = 1000*toc(started); return;
end
if strcmp(tool,'locate_anomalies')
    response = dispatchLocate(payload,folder,response);
    response.duration_ms = 1000*toc(started);
    return;
end
if strcmp(tool,'query_operating_context')
    response = dispatchContext(payload,folder,response);
    response.duration_ms = 1000*toc(started); return;
elseif strcmp(tool,'lookup_method_conditions')
    response = dispatchMethods(payload,folder,response);
    response.duration_ms = 1000*toc(started); return;
end
allowed = {'case_id'};
if strcmp(tool,'compute_residual_bundle'), allowed = {'case_id','load_assumption'}; end
if ~isstruct(payload) || ~isscalar(payload) || ...
        ~isfield(payload,'case_id') || ~all(ismember(fieldnames(payload),allowed)) || ...
        ~isTextScalar(payload.case_id)
    response.error_code = 'invalid_arguments';
    response.duration_ms = 1000*toc(started);
    return;
end
caseId = char(payload.case_id);
if isempty(regexp(caseId,'^CASE-[0-9a-f]{32}$','once'))
    response.error_code = 'invalid_case_id';
    response.duration_ms = 1000*toc(started);
    return;
end
release = fullfile(fileparts(folder),'data','agent_visible','observations_v1');
manifest = fullfile(folder,'registry','observations_v1_manifest.json');
if strcmp(tool,'inspect_case')
    response = inspect_case_core(caseId,release,manifest);
else
    mode = 'none';
    if isfield(payload,'load_assumption')
        if ~isTextScalar(payload.load_assumption)
            response.error_code = 'invalid_arguments';
            response.duration_ms = 1000*toc(started);
            return;
        end
        mode = char(payload.load_assumption);
    end
    if ~ismember(mode,{'none','prescribed_command'})
        response.error_code = 'invalid_load_assumption';
        response.duration_ms = 1000*toc(started);
        return;
    end
    evidenceRoot = fullfile(fileparts(folder),'data','agent_visible','derived_v1');
    algorithm = fullfile(folder,'registry','residual_algorithm_v1.json');
    response = compute_residual_core(caseId,mode,release,manifest,evidenceRoot,algorithm);
end
response.duration_ms = 1000*toc(started);
end

function response = dispatchLocate(payload,folder,response)
response.tool_version = 'EMA-LOCATE-1.0';
allowed = {'residual_evidence_id','threshold_version','analysis_interval_s'};
if ~isstruct(payload) || ~isscalar(payload) || ~isfield(payload,'residual_evidence_id') || ...
        ~all(ismember(fieldnames(payload),allowed)) || ~isTextScalar(payload.residual_evidence_id)
    response.error_code = 'invalid_arguments'; return;
end
id = char(payload.residual_evidence_id);
if isempty(regexp(id,'^BUNDLE-[0-9a-f]{64}$','once'))
    response.error_code = 'invalid_residual_evidence_id'; return;
end
if isfield(payload,'threshold_version') && (~isTextScalar(payload.threshold_version) || ...
        ~strcmp(char(payload.threshold_version),'EMA-DETECTOR-IDEAL-1.0'))
    response.error_code = 'invalid_threshold_version'; return;
end
interval = [];
if isfield(payload,'analysis_interval_s')
    interval = payload.analysis_interval_s;
    if ~isa(interval,'double') || ~isreal(interval) || ~isvector(interval) || numel(interval)~=2 || ...
            any(~isfinite(interval)) || any(interval<0) || interval(1)>interval(2)
        response.error_code = 'invalid_analysis_interval'; return;
    end
    interval = interval(:)';
end
root = fileparts(folder);
response = locate_anomalies_core(id,interval, ...
    fullfile(root,'data','agent_visible','observations_v1'), ...
    fullfile(folder,'registry','observations_v1_manifest.json'), ...
    fullfile(root,'data','agent_visible','derived_v1'), ...
    fullfile(folder,'registry','residual_algorithm_v1.json'),fullfile(folder,'registry'));
end

function response = dispatchContext(payload,folder,response)
response.tool_version = 'EMA-CONTEXT-1.0';
allowedFields = {'load_command','load_compensation','independent_load','initial_reference','signal_acquisition'};
if ~isstruct(payload) || ~isscalar(payload) || ~isfield(payload,'case_id') || ...
        ~all(ismember(fieldnames(payload),{'case_id','fields','time_range_s'})) || ~isTextScalar(payload.case_id)
    response.error_code = 'invalid_arguments'; return;
end
caseId = char(payload.case_id);
if isempty(regexp(caseId,'^CASE-[0-9a-f]{32}$','once'))
    response.error_code = 'invalid_case_id'; return;
end
fields = allowedFields;
if isfield(payload,'fields')
    value = payload.fields;
    if ~((iscellstr(value) && isvector(value)) || (isstring(value) && isvector(value) && ~any(ismissing(value)))) || isempty(value)
        response.error_code = 'invalid_context_fields'; return;
    end
    fields = cellstr(string(value(:)'));
    if numel(unique(fields))~=numel(fields) || ~all(ismember(fields,allowedFields))
        response.error_code = 'invalid_context_fields'; return;
    end
end
interval = [];
if isfield(payload,'time_range_s')
    interval = payload.time_range_s;
    if ~isa(interval,'double') || ~isreal(interval) || ~isvector(interval) || numel(interval)~=2 || ...
            any(~isfinite(interval)) || any(interval<0) || interval(1)>interval(2)
        response.error_code = 'invalid_time_range'; return;
    end
    interval = interval(:)';
end
response = query_context_core(caseId,fields,interval, ...
    fullfile(fileparts(folder),'data','agent_visible','observations_v1'), ...
    fullfile(folder,'registry','observations_v1_manifest.json'));
end

function response = dispatchMethods(payload,folder,response)
response.tool_version = 'EMA-METHOD-LOOKUP-1.0';
ids = {'all','position_consistency','phase_sum','torque_balance','motion_validity', ...
    'alarm_persistence','cross_channel_response','hypothesis_comparison'};
if ~isstruct(payload) || ~isscalar(payload) || ~isfield(payload,'method_id') || ...
        ~all(ismember(fieldnames(payload),{'method_id','case_id','method_version'})) || ~isTextScalar(payload.method_id)
    response.error_code = 'invalid_arguments'; return;
end
methodId = char(payload.method_id);
if ~ismember(methodId,ids), response.error_code = 'invalid_method_id'; return; end
if isfield(payload,'method_version') && (~isTextScalar(payload.method_version) || ...
        ~strcmp(char(payload.method_version),'EMA-METHODS-1.0'))
    response.error_code = 'invalid_method_version'; return;
end
caseId = '';
if isfield(payload,'case_id')
    if ~isTextScalar(payload.case_id) || isempty(regexp(char(payload.case_id),'^CASE-[0-9a-f]{32}$','once'))
        response.error_code = 'invalid_case_id'; return;
    end
    caseId = char(payload.case_id);
end
response = lookup_conditions_core(methodId,caseId, ...
    fullfile(fileparts(folder),'data','agent_visible','observations_v1'), ...
    fullfile(folder,'registry','observations_v1_manifest.json'),fullfile(folder,'registry'));
end

function yes = isTextScalar(value)
yes = (ischar(value) && isrow(value)) || ...
    (isstring(value) && isscalar(value) && ~ismissing(value));
end

function value = emptyResponse()
value = struct('tool','inspect_case','tool_version','EMA-INSPECT-1.0', ...
    'case_id','','status','execution_error','error_code','', ...
    'input_hash','','parameter_version','','model_hash','', ...
    'preconditions',[],'result',struct(),'evidence',[], ...
    'warnings',{{}},'duration_ms',0);
end
