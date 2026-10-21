function report = export_stage4_boundaries()
% Research-only positive-list export. No generation truth enters this release.
root = fileparts(fileparts(mfilename('fullpath')));
out = fullfile(root,'results','EXP-20261020-018');
private = fullfile(root,'data','evaluation_private','EXP-20261020-018');
destination = fullfile(root,'data','agent_visible','observations_boundary_v1');
assert(~isfolder(destination) && ~isfolder(private),'Paper:ExistingRelease','Preserve releases.');
mkdir(private);
stage = fullfile(private,'pending_public'); mkdir(stage);
policy = jsondecode(fileread(fullfile(root,'configs/observation_export_v1.json')));
runs = {'EXP-20261020-016','EXP-20261020-017'};
labels = {'F1_initial_constant_offset','healthy_load_compensation_mismatch'};
mapping = struct([]); catalog = struct([]); checks = struct([]);
for k=1:2
    identity = struct('case_id',opaque('CASE'),'group_id',opaque('RUN'), ...
        'source_run_id',runs{k},'reference_class',labels{k},'partition','development');
    mapping = [mapping;identity]; %#ok<AGROW>
    caseFolder = fullfile(stage,identity.case_id); mkdir(caseFolder);
    saved = load(fullfile(root,'results',runs{k},'observations_aligned.mat'),'observations');
    observations = select_public_observations(saved.observations,policy);
    save(fullfile(caseFolder,'observations.mat'),'observations','-v7');
    % The existing strict numerical reader can verify this per-case subrelease.
    for filename = {'channel_contract.json','parameters.json','operating_context.json'}
        copyfile(fullfile(root,'data/agent_visible/observations_v1',filename{1}), ...
            fullfile(caseFolder,filename{1}));
    end
    native = load(fullfile(root,'data/evaluation_private',runs{k},'native_acquisition.mat'),'acquisition');
    force = native.acquisition.externalInput.getElement('ExternalForce');
    torque = native.acquisition.externalInput.getElement('LoadTorque');
    command = struct('time_s',force.Time,'external_force_command_N',force.Data, ...
        'direct_torque_command_Nm',torque.Data,'compensation_time_s',observations.time_s, ...
        'compensation_force_N',interp1(force.Time,force.Data,observations.time_s,'linear'), ...
        'compensation_direct_torque_Nm',zeros(size(observations.time_s)));
    save(fullfile(caseFolder,'operating_context.mat'),'command','-v7');
    processing = load(fullfile(root,'results',runs{k},'residuals.mat'),'assumption');
    assumedLoad = struct('time_s',observations.time_s, ...
        'external_force_N',interp1(processing.assumption.time_s,processing.assumption.external_force_N,observations.time_s,'linear'), ...
        'direct_torque_Nm',zeros(size(observations.time_s)));
    save(fullfile(caseFolder,'diagnostic_assumption.mat'),'assumedLoad','-v7');
    assumptionInfo = struct('assumption_id',opaque('ASSUMP'),'source_kind','recorded_diagnostic_assumption', ...
        'independent_measurement',false,'time_range_s',[0 0.8], ...
        'explicit_selection_required',true,'force_unit','N', ...
        'force_min_N',min(assumedLoad.external_force_N),'force_max_N',max(assumedLoad.external_force_N), ...
        'interpretation_limit','DIAGNOSTIC_SETTING_DOES_NOT_ESTABLISH_ACTUAL_LOAD');
    writeJson(fullfile(caseFolder,'diagnostic_assumption.json'),assumptionInfo);
    meta = struct('case_id',identity.case_id,'group_id',identity.group_id, ...
        'schema_version','EMA-OBS-1.0','parameter_version','EMA-NOMINAL-1.0', ...
        'context_id','CTX-PRESCRIBED-1.0','sample_count',160001,'time_range_s',[0 0.8], ...
        'observations_sha256',paper_file_sha256(fullfile(caseFolder,'observations.mat')));
    writeJson(fullfile(caseFolder,'metadata.json'),meta);
    writeJson(fullfile(caseFolder,'catalog.json'),struct('schema_version','EMA-OBS-1.0', ...
        'cases',struct('case_id',identity.case_id,'group_id',identity.group_id)));
    filenames = {'catalog.json','channel_contract.json','parameters.json','operating_context.json', ...
        'operating_context.mat','diagnostic_assumption.mat','diagnostic_assumption.json'};
    entries = struct([]);
    for j=1:numel(filenames)
        entries = [entries;struct('path',filenames{j},'sha256',paper_file_sha256(fullfile(caseFolder,filenames{j})))]; %#ok<AGROW>
    end
    % Reader paths are CASE/metadata and CASE/observations within the subrelease.
    % Keep a single physical observation file; the subrelease root is stage.
    catalog = [catalog;struct('case_id',identity.case_id,'group_id',identity.group_id)]; %#ok<AGROW>
    checks = [checks;struct('case_id',identity.case_id,'seven_fields_equal', ...
        isequal(observations,select_public_observations(saved.observations,policy)), ...
        'command_matches_saved_input',isequal(command.external_force_command_N,force.Data), ...
        'public_field_count',numel(fieldnames(observations)), ...
        'command_max_N',max(command.external_force_command_N), ...
        'assumption_max_N',max(assumedLoad.external_force_N))]; %#ok<AGROW>
    % Each case gets a complete strict-reader root with a nested CASE path.
    nested = fullfile(caseFolder,identity.case_id); mkdir(nested);
    movefile(fullfile(caseFolder,'observations.mat'),fullfile(nested,'observations.mat'));
    movefile(fullfile(caseFolder,'metadata.json'),fullfile(nested,'metadata.json'));
    for name = {'observations.mat','metadata.json'}
        relative = [identity.case_id '/' name{1}];
        entries = [entries;struct('path',relative,'sha256',paper_file_sha256(fullfile(caseFolder,relative)))]; %#ok<AGROW>
    end
    writeJson(fullfile(caseFolder,'manifest.json'),struct('release_version','EMA-OBS-1.0','files',entries));
end
writeJson(fullfile(stage,'catalog.json'),struct('release_version','EMA-BOUNDARY-OBS-1.0','cases',catalog));
writeJson(fullfile(private,'case_mapping.json'),mapping);
assert(all([checks.seven_fields_equal]) && all([checks.command_matches_saved_input]), ...
    'Paper:ExportMismatch','Export did not preserve inputs.');
movefile(stage,destination);
index = catalog;
for k=1:numel(index)
    index(k).manifest_sha256 = paper_file_sha256(fullfile(destination,index(k).case_id,'manifest.json'));
end
writeJson(fullfile(root,'tools/registry_stage4/boundary_release_index.json'), ...
    struct('release_version','EMA-BOUNDARY-OBS-1.0', ...
    'catalog_sha256',paper_file_sha256(fullfile(destination,'catalog.json')),'cases',index));
report = struct('status','exported_pending_tool_validation','case_count',2, ...
    'new_simulations',0,'agent_runs',0,'checks',checks, ...
    'runtime_entrypoint','ema_tool_stage4','current_agent_worker_switched',false);
writeJson(fullfile(out,'export_report.json'),report);
disp(report);
end

function id = opaque(prefix)
id = [prefix '-' strrep(char(java.util.UUID.randomUUID()),'-','')];
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8');
assert(handle>=0,'Paper:Write','Cannot write export.');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
