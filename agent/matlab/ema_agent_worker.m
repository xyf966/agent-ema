function ema_agent_worker(jobId,profile)
% Fixed six-tool worker. No generated MATLAB code, model loading or simulation.
arguments
    jobId (1,:) char
    profile (1,:) char = 'stage3'
end
profile = validatestring(profile,{'stage3','stage4'});
assert(~isempty(regexp(jobId,'^JOB-[0-9a-f]{32}$','once')), ...
    'Paper:WorkerJob','Invalid worker job.');
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
folder = fullfile(root,'work','agent_bridge',jobId);
assert(isfolder(folder),'Paper:WorkerFolder','Missing worker folder.');
toolFolder = fullfile(root,'tools');
addpath(toolFolder,'-begin');
assert(strcmpi(which('ema_tool'),fullfile(toolFolder,'ema_tool.m')), ...
    'Paper:WorkerShadowing','Unexpected dispatcher.');
dispatcher = @ema_tool;
if strcmp(profile,'stage4')
    assert(strcmpi(which('ema_tool_stage4'),fullfile(toolFolder,'ema_tool_stage4.m')), ...
        'Paper:WorkerShadowing','Unexpected stage4 dispatcher.');
    dispatcher = @ema_tool_stage4;
end
allowed = {'inspect_case','compute_residual_bundle','locate_anomalies', ...
    'query_operating_context','lookup_method_conditions','plot_evidence'};
issues = checkcode(mfilename('fullpath'),'-id');
writeJson(fullfile(folder,'ready.json'),struct('status','ready','matlab_version',version, ...
    'dispatcher_local',true,'model_loaded',false,'simulation_executed',false, ...
    'tool_profile',profile,'dispatcher',func2str(dispatcher), ...
    'worker_code_analyzer_issue_count',numel(issues)));
started = tic;
sequence = 1;
while toc(started)<600
    if isfile(fullfile(folder,'stop')), break; end
    requestPath = fullfile(folder,sprintf('request_%04d.json',sequence));
    if ~isfile(requestPath), pause(0.1); continue; end
    envelope = struct('sequence',sequence,'bridge_status','error','response',struct());
    try
        request = jsondecode(fileread(requestPath));
        assert(isstruct(request) && isscalar(request) && ...
            isequal(sort(fieldnames(request)),sort({'sequence';'tool';'arguments'})) && ...
            isequal(request.sequence,sequence) && ischar(request.tool) && ...
            ismember(request.tool,allowed),'Paper:WorkerRequest','Invalid request.');
        envelope.response = dispatcher(request.tool,request.arguments);
        envelope.bridge_status = 'ok';
    catch
        % Never return MATLAB exception messages or local/private paths.
        envelope.bridge_status = 'execution_error';
    end
    writeJson(fullfile(folder,sprintf('response_%04d.json',sequence)),envelope);
    sequence = sequence+1;
end
writeJson(fullfile(folder,'stopped.json'),struct('status','stopped','requests_processed',sequence-1));
end

function writeJson(path,value)
temporary = [path '.tmp'];
handle = fopen(temporary,'w','n','UTF-8');
assert(handle>=0,'Paper:WorkerWrite','Cannot write worker response.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(value));
clear cleanup;
movefile(temporary,path,'f');
end
