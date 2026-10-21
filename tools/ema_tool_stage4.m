function response = ema_tool_stage4(tool,payload)
% Six-tool development adapter. Only approved anonymous identities are accepted.
% Legacy seven cases retain the unchanged ema_tool implementation and outputs.
timer = tic;
response = struct('tool','','tool_version','EMA-STAGE4-ADAPTER-1.0', ...
    'case_id','','status','execution_error','error_code','invalid_arguments', ...
    'result',struct(),'evidence',[],'warnings',{{}},'duration_ms',0);
try
    names = {'inspect_case','compute_residual_bundle','locate_anomalies', ...
        'query_operating_context','lookup_method_conditions','plot_evidence'};
    require(textScalar(tool) && ismember(char(tool),names),'unsupported_tool_or_call');
    tool = char(tool); response.tool = tool;
    require(isstruct(payload) && isscalar(payload),'invalid_arguments');
    allowed = struct('inspect_case',{{'case_id'}}, ...
        'compute_residual_bundle',{{'case_id','load_assumption'}}, ...
        'locate_anomalies',{{'residual_evidence_id','threshold_version','analysis_interval_s'}}, ...
        'query_operating_context',{{'case_id','fields','time_range_s'}}, ...
        'lookup_method_conditions',{{'method_id','case_id','method_version'}}, ...
        'plot_evidence',{{'residual_evidence_id'}});
    require(all(ismember(fieldnames(payload),allowed.(tool))),'invalid_arguments');
    required = 'case_id';
    if ismember(tool,{'locate_anomalies','plot_evidence'}), required = 'residual_evidence_id'; end
    if strcmp(tool,'lookup_method_conditions'), required = 'method_id'; end
    require(isfield(payload,required) && textScalar(payload.(required)),'invalid_arguments');
    folder = fileparts(mfilename('fullpath')); root = fileparts(folder);
    registry = fullfile(folder,'registry');
    derived = fullfile(root,'data/agent_visible/derived_boundary_v1');
    releaseRoot = fullfile(root,'data/agent_visible/observations_boundary_v1');
    caseId = '';
    if isfield(payload,'case_id')
        require(textScalar(payload.case_id) && ~isempty(regexp(char(payload.case_id),'^CASE-[0-9a-f]{32}$','once')),'invalid_case_id');
        caseId = char(payload.case_id);
    elseif ismember(tool,{'locate_anomalies','plot_evidence'})
        id = char(payload.residual_evidence_id);
        require(~isempty(regexp(id,'^BUNDLE-[0-9a-f]{64}$','once')),'invalid_residual_evidence_id');
        metadataPath = fullfile(derived,id,'metadata.json');
        if isfile(metadataPath)
            metadata = jsondecode(fileread(metadataPath)); caseId = metadata.case_id;
            require(~isempty(regexp(caseId,'^CASE-[0-9a-f]{32}$','once')),'invalid_case_id');
        end
    end
    index = jsondecode(fileread(fullfile(folder,'registry_stage4/boundary_release_index.json')));
    match = index.cases(strcmp({index.cases.case_id},caseId));
    if isempty(match)
        response = ema_tool(tool,payload); return;
    end
    require(isscalar(match) && strcmp(tool_sha256(fullfile(releaseRoot,'catalog.json'),'file'),index.catalog_sha256),'release_integrity_mismatch');
    release = fullfile(releaseRoot,caseId);
    manifest = fullfile(release,'manifest.json');
    require(strcmp(tool_sha256(manifest,'file'),match.manifest_sha256),'release_integrity_mismatch');
    algorithm = fullfile(registry,'residual_algorithm_v1.json');
    switch tool
        case 'inspect_case'
            response = inspect_case_core(caseId,release,manifest);
        case 'compute_residual_bundle'
            mode = 'none';
            if isfield(payload,'load_assumption')
                require(textScalar(payload.load_assumption),'invalid_load_assumption');
                mode = char(payload.load_assumption);
            end
            require(ismember(mode,{'none','prescribed_command','recorded_assumption'}),'invalid_load_assumption');
            response = compute_boundary_core(caseId,mode,release,manifest,derived,algorithm);
        case 'locate_anomalies'
            if isfield(payload,'threshold_version')
                require(textScalar(payload.threshold_version) && strcmp(char(payload.threshold_version),'EMA-DETECTOR-IDEAL-1.0'),'invalid_threshold_version');
            end
            interval = getInterval(payload,'analysis_interval_s');
            response = locate_boundary_core(char(payload.residual_evidence_id),interval,release,manifest,derived,algorithm,registry);
        case 'query_operating_context'
            fields = {'load_command','load_compensation','independent_load','initial_reference','signal_acquisition'};
            if isfield(payload,'fields')
                require((iscellstr(payload.fields) || isstring(payload.fields)) && isvector(payload.fields) && ~isempty(payload.fields),'invalid_context_fields');
                selected = cellstr(string(payload.fields(:)'));
                require(numel(unique(selected))==numel(selected) && all(ismember(selected,fields)),'invalid_context_fields');
                fields = selected;
            end
            interval = getInterval(payload,'time_range_s');
            response = query_context_core(caseId,fields,interval,release,manifest);
            if strcmp(response.status,'ok')
                [assumedLoad,info,hash] = read_boundary_assumption(release,manifest);
                response.input_hash = tool_sha256([response.input_hash '|' hash],'text');
                for k=1:numel(response.result.records)
                    id = ['CTX-' response.input_hash '-' num2str(k)];
                    row = response.result.records(k);
                    row.evidence_id = id;
                    response.evidence(k).id = id;
                    if strcmp(row.name,'load_compensation')
                        row.source_id = info.assumption_id;
                        row.source_kind = info.source_kind;
                        row.interpretation_limit = info.interpretation_limit;
                        row.value.explicit_assumption_required = true;
                        if isempty(interval), interval = [assumedLoad.time_s(1),assumedLoad.time_s(end)]; end
                        selected = assumedLoad.time_s>=interval(1) & assumedLoad.time_s<=interval(2);
                        if any(selected)
                            row.value.force_min_N = min(assumedLoad.external_force_N(selected));
                            row.value.force_max_N = max(assumedLoad.external_force_N(selected));
                        end
                        response.evidence(k).source_id = info.assumption_id;
                        response.evidence(k).source_kind = info.source_kind;
                    end
                    response.result.records(k) = row;
                end
                response.warnings{end+1} = 'RECORDED_ASSUMPTION_DISTINCT_FROM_COMMAND_RECORD';
            end
        case 'lookup_method_conditions'
            ids = {'all','position_consistency','phase_sum','torque_balance','motion_validity', ...
                'alarm_persistence','cross_channel_response','hypothesis_comparison'};
            require(ismember(char(payload.method_id),ids),'invalid_method_id');
            if isfield(payload,'method_version')
                require(textScalar(payload.method_version) && strcmp(char(payload.method_version),'EMA-METHODS-1.0'),'invalid_method_version');
            end
            response = lookup_conditions_core(char(payload.method_id),caseId,release,manifest,registry);
        case 'plot_evidence'
            response = plot_boundary_core(char(payload.residual_evidence_id),release,manifest,derived,algorithm,registry, ...
                fullfile(root,'data/agent_visible/figures_boundary_v1'));
    end
catch issue
    response.status = 'execution_error'; response.error_code = 'boundary_execution_failed';
    if startsWith(issue.identifier,'Boundary:') || startsWith(issue.identifier,'Residual:')
        response.error_code = extractAfter(issue.identifier,':');
    end
    response.result = struct(); response.evidence = [];
end
response.duration_ms = 1000*toc(timer);
end

function interval = getInterval(payload,name)
interval = [];
if isfield(payload,name)
    interval = payload.(name);
    require(isa(interval,'double') && isreal(interval) && isvector(interval) && numel(interval)==2 && ...
        all(isfinite(interval)) && interval(1)>=0 && interval(1)<=interval(2),'invalid_time_interval');
    interval = interval(:)';
end
end

function yes = textScalar(value)
yes = (ischar(value) && isrow(value)) || (isstring(value) && isscalar(value) && ~ismissing(value));
end

function require(condition,code)
assert(isscalar(condition) && condition,['Boundary:' code],'Boundary adapter check failed.');
end
