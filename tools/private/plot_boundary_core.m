function response = plot_boundary_core(id,release,manifest,derived,algorithm,registry,figureRoot)
response = struct('tool','plot_evidence','tool_version','EMA-BOUNDARY-PLOT-1.0', ...
    'case_id','','status','execution_error','error_code','', ...
    'input_hash','','parameter_version','','model_hash','', ...
    'preconditions',[],'result',struct(),'evidence',[], ...
    'warnings',{{}},'duration_ms',0);
try
    [r,parent] = read_boundary_bundle(id,release,manifest,derived,algorithm);
    alarms = locate_boundary_core(id,[],release,manifest,derived,algorithm,registry);
    if ~ismember(alarms.status,{'ok','insufficient_data'}) || ~isfield(alarms.result,'channels')
        response.status = alarms.status; response.error_code = alarms.error_code; return;
    end
    [inspection,~,observations] = inspect_case_core(parent.case_id,release,manifest);
    require(strcmp(inspection.status,'ok'),'observation_validation_failed');
    codeFolder = fileparts(mfilename('fullpath'));
    rendererHash = tool_sha256(fullfile(codeFolder,'render_boundary_evidence.m'),'file');
    workerHash = tool_sha256(fullfile(codeFolder,'plot_boundary_core.m'),'file');
    inputHash = tool_sha256(strjoin({'EMA-BOUNDARY-PLOT-1.0',id,parent.result.artifact_sha256, ...
        inspection.input_hash,alarms.input_hash,rendererHash,workerHash},'|'),'text');
    plotId = ['PLOT-' inputHash];
    base = char(java.io.File(figureRoot).getCanonicalPath());
    folder = char(java.io.File(fullfile(figureRoot,plotId)).getCanonicalPath());
    require(startsWith(lower(folder),lower([base filesep])),'access_denied');
    png = child(folder,'overview.png'); fig = child(folder,'overview.fig');
    metaPath = child(folder,'metadata.json');
    mode = parent.result.load_assumption;
    meta = struct('plot_id',plotId,'tool_version','EMA-BOUNDARY-PLOT-1.0','input_hash',inputHash, ...
        'case_id',parent.case_id,'residual_evidence_id',id, ...
        'residual_artifact_sha256',parent.result.artifact_sha256, ...
        'anomaly_input_hash',alarms.input_hash,'renderer_sha256',rendererHash, ...
        'worker_sha256',workerHash,'load_assumption',mode, ...
        'threshold_version',alarms.threshold_version, ...
        'observation_stride',200,'residual_stride',1,'png_sha256','','fig_sha256','');
    reused = isfolder(folder);
    if reused
        require(isfile(png) && isfile(fig) && isfile(metaPath),'incomplete_plot_artifact');
        meta.png_sha256 = tool_sha256(png,'file'); meta.fig_sha256 = tool_sha256(fig,'file');
        require(isequaln(jsondecode(fileread(metaPath)),meta),'plot_integrity_mismatch');
    else
        mkdir(folder);
        render_boundary_evidence(observations,r,alarms,parent.case_id,id,mode,png,fig);
        meta.png_sha256 = tool_sha256(png,'file'); meta.fig_sha256 = tool_sha256(fig,'file');
        handle = fopen(metaPath,'w','n','UTF-8');
        require(handle>=0,'plot_write_failed');
        cleanup = onCleanup(@() fclose(handle));
        fprintf(handle,'%s',jsonencode(meta,'PrettyPrint',true));
        clear cleanup;
    end
    response.case_id = parent.case_id; response.input_hash = inputHash;
    response.parameter_version = parent.parameter_version;
    response.preconditions = parent.preconditions; response.warnings = alarms.warnings;
    response.status = 'ok';
    response.result = struct('plot_id',plotId,'residual_evidence_id',id, ...
        'png_ref',['figure://' plotId '/overview.png'], ...
        'editable_fig_ref',['figure://' plotId '/overview.fig'], ...
        'png_sha256',meta.png_sha256,'fig_sha256',meta.fig_sha256, ...
        'load_assumption',mode,'independent_load_supported',false, ...
        'partial_result',alarms.result.partial_result,'artifact_reused',reused, ...
        'observation_stride',200,'residual_stride',1, ...
        'time_range_s',[observations.time_s(1),observations.time_s(end)]);
    response.evidence = struct('id',plotId,'quantity','observation_residual_overview', ...
        'parent_evidence_id',id,'valid',true,'interpretation_basis','visualization_only');
catch issue
    response.status = 'execution_error'; response.error_code = 'plot_execution_failed';
    if startsWith(issue.identifier,'Anomaly:') || startsWith(issue.identifier,'Plot:')
        response.error_code = extractAfter(issue.identifier,':');
        if ismember(response.error_code,{'unknown_residual_evidence','residual_source_unavailable'})
            response.status = 'insufficient_data';
        end
    end
    response.result = struct(); response.evidence = [];
end
end

function path = child(folder,name)
path = char(java.io.File(fullfile(folder,name)).getCanonicalPath());
require(startsWith(lower(path),lower([folder filesep])),'access_denied');
end

function require(yes,code)
assert(isscalar(yes) && yes,['Plot:' code],'Plot check failed.');
end
