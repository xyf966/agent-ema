function report = inventory_stage2_data()
% Research-only MAT inventory. Never register this function as an Agent tool.
% Reads project-local data/results; does not run models or change MATLAB paths.
root = fileparts(fileparts(mfilename('fullpath')));
output = fullfile(root,'results','EXP-20261019-003');
if ~isfolder(output), mkdir(output); end
files = [dir(fullfile(root,'data','**','*.mat')); ...
    dir(fullfile(root,'results','**','*.mat'))];
rows = struct('file',{},'field',{},'class',{},'size',{}, ...
    'category',{},'nonfinite_count',{},'inspection',{});
checks = struct('file',{},'field',{},'sample_count',{}, ...
    'time_range_s',{},'median_dt_s',{},'max_dt_error_s',{}, ...
    'channels',{},'unexpected_fields',{},'valid',{});
fileReports = struct('file',{},'bytes',{},'variables',{},'status',{},'error',{});
required = {'time_s','x_meas_m','omega_meas_radps','iabc_meas_A', ...
    'id_meas_A','iq_meas_A','x_ref_m'};
context = {'loadKnown','external_force_known_N','direct_torque_known_Nm'};
for fileIndex = 1:numel(files)
    path = fullfile(files(fileIndex).folder,files(fileIndex).name);
    relative = strrep(path(numel(root)+2:end),'\','/');
    entry = struct('file',relative,'bytes',files(fileIndex).bytes, ...
        'variables',[],'status','ok','error','');
    try
        entry.variables = whos('-file',path);
        % Local research MAT files; top-level objects are not exposed to Agent.
        loaded = load(path);
        topLevelNames = fieldnames(loaded);
        for topLevelIndex = 1:numel(topLevelNames)
            visit(loaded.(topLevelNames{topLevelIndex}), ...
                topLevelNames{topLevelIndex},relative,0);
        end
    catch issue
        entry.status = 'inspection_error';
        entry.error = getReport(issue,'basic','hyperlinks','off');
    end
    fileReports(end+1) = entry; %#ok<AGROW>
end
report = struct('experiment_id','EXP-20261019-003', ...
    'stage',2,'step',1,'purpose','research_only_data_inventory', ...
    'generated_at',char(datetime('now','TimeZone','Asia/Shanghai')), ...
    'matlab_version',version,'simulation_executed',false, ...
    'agent_calls',0,'anonymous_export_completed',false, ...
    'file_count',numel(files),'inspection_error_count', ...
    nnz(~strcmp({fileReports.status},'ok')), ...
    'files',fileReports,'fields',rows,'observation_checks',checks);
writeJson(fullfile(output,'mat_inventory.json'),report);
writetable(struct2table(rows),fullfile(output,'mat_fields.csv'),'Encoding','UTF-8');
fprintf('Inventoried %d MAT files, %d field entries, %d errors.\n', ...
    numel(files),numel(rows),report.inspection_error_count);
fprintf('Found %d observation structs; %d pass aligned-input checks.\n', ...
    numel(checks),nnz([checks.valid]));

    function visit(value,field,file,depth)
        category = classify(field);
        row = struct('file',file,'field',field,'class',class(value), ...
            'size',mat2str(size(value)),'category',category, ...
            'nonfinite_count',NaN,'inspection','complete');
        if isnumeric(value)
            row.nonfinite_count = nnz(~isfinite(value));
        end
        if depth > 20
            row.inspection = 'depth_limit';
            rows(end+1) = row;
            return;
        end
        if isobject(value) && ~istable(value) && ...
                ~isa(value,'timeseries') && ...
                ~isa(value,'Simulink.SimulationData.Dataset') && ...
                ~isa(value,'Simulink.SimulationData.Signal') && ~isstring(value)
            row.inspection = 'opaque_object_private_not_exportable';
        end
        rows(end+1) = row;
        if isstruct(value)
            names = fieldnames(value);
            for k = 1:numel(value)
                prefix = field;
                if numel(value)>1, prefix = sprintf('%s(%d)',field,k); end
                if all(isfield(value(k),required))
                    inspectObservation(value(k),prefix,file);
                end
                for n = 1:numel(names)
                    visit(value(k).(names{n}),[prefix '.' names{n}],file,depth+1);
                end
            end
        elseif iscell(value)
            for k = 1:numel(value)
                visit(value{k},sprintf('%s{%d}',field,k),file,depth+1);
            end
        elseif istable(value)
            names = value.Properties.VariableNames;
            for k = 1:numel(names)
                visit(value.(names{k}),[field '.' names{k}],file,depth+1);
            end
        elseif isa(value,'Simulink.SimulationData.Dataset')
            names = value.getElementNames;
            for k = 1:value.numElements
                visit(value.getElement(k),sprintf('%s{%d:%s}',field,k,names{k}),file,depth+1);
            end
        elseif isa(value,'Simulink.SimulationData.Signal')
            visit(value.Values,[field '.Values'],file,depth+1);
        elseif isa(value,'timeseries')
            visit(value.Time,[field '.Time'],file,depth+1);
            visit(value.Data,[field '.Data'],file,depth+1);
        end
    end

    function inspectObservation(value,field,file)
        t = value.time_s(:);
        increments = diff(t);
        dt = median(increments);
        channelInfo = struct('name',{},'size',{},'finite',{},'aligned',{});
        valid = numel(t)>2 && all(isfinite(t)) && all(increments>0) && ...
            abs(dt-5e-6)<1e-10 && max(abs(increments-dt))<1e-10;
        for k = 2:numel(required)
            v = value.(required{k});
            width = 1;
            if strcmp(required{k},'iabc_meas_A'), width = 3; end
            item = struct('name',required{k},'size',size(v), ...
                'finite',all(isfinite(v(:))), ...
                'aligned',isequal(size(v),[numel(t),width]));
            channelInfo(end+1) = item; %#ok<AGROW>
            valid = valid && item.finite && item.aligned;
        end
        check = struct('file',file,'field',field,'sample_count',numel(t), ...
            'time_range_s',[t(1),t(end)],'median_dt_s',dt, ...
            'max_dt_error_s',max(abs(increments-dt)), ...
            'channels',channelInfo,'unexpected_fields', ...
            {setdiff(fieldnames(value),[required,context])},'valid',valid);
        checks(end+1) = check;
    end
end

function category = classify(field)
% Triage only, NOT an export permission. Unknown fields remain private.
lowerField = lower(field);
if ~isempty(regexp(lowerField, ...
        'config|generation|evaluation|appliedfault|injected|fault|biasatalarm|resistanceatalarm|delay_ms|prefault|condition|case(name)?|label', 'once'))
    category = 'private_truth_or_label_context';
elseif ~isempty(regexp(lowerField,'external_force_known|direct_torque_known|loadknown|externalinput', 'once'))
    category = 'context_requires_provenance_review';
elseif ~isempty(regexp(lowerField,'(^|\.)(time_s|x_meas_m|omega_meas_radps|iabc_meas_a|id_meas_a|iq_meas_a|x_ref_m)$','once'))
    category = 'observation_candidate_only';
elseif ~isempty(regexp(lowerField,'nominal|motor|mechanics','once'))
    category = 'nominal_parameter_requires_whitelist';
elseif ~isempty(regexp(lowerField,'residual|result|alarm|summary|detector|comparison','once'))
    category = 'derived_or_reference_requires_review';
else
    category = 'unreviewed_private_by_default';
end
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8');
assert(handle>=0,'Paper:InventoryWrite','Cannot write inventory report.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
