function [assumedLoad,info,hash] = read_boundary_assumption(release,manifestPath)
% Fixed roles only. Hash and shape checks prevent unapproved truth containers.
manifest = jsondecode(fileread(manifestPath));
names = {'diagnostic_assumption.mat','diagnostic_assumption.json'};
hashes = cell(1,2);
for k=1:2
    entry = manifest.files(strcmp({manifest.files.path},names{k}));
    assert(isscalar(entry),'Residual:access_denied','Unapproved role.');
    path = fullfile(release,names{k});
    hashes{k} = tool_sha256(path,'file');
    assert(strcmp(hashes{k},entry.sha256),'Residual:integrity_mismatch','Assumption changed.');
end
path = fullfile(release,names{1});
header = whos('-file',path);
assert(isscalar(header) && strcmp(header.name,'assumedLoad') && strcmp(header.class,'struct'), ...
    'Residual:unapproved_data_structure','Unapproved assumption container.');
saved = load(path,'assumedLoad'); assumedLoad = saved.assumedLoad;
assert(isequal(sort(fieldnames(assumedLoad)),sort({'time_s';'external_force_N';'direct_torque_Nm'})) && ...
    all(structfun(@(v) isa(v,'double') && iscolumn(v) && isreal(v) && all(isfinite(v)),assumedLoad)) && ...
    isequal(size(assumedLoad.time_s),size(assumedLoad.external_force_N),size(assumedLoad.direct_torque_Nm)) && ...
    all(diff(assumedLoad.time_s)>0),'Residual:invalid_command_data','Invalid assumption arrays.');
info = jsondecode(fileread(fullfile(release,names{2})));
assert(strcmp(info.source_kind,'recorded_diagnostic_assumption') && ...
    isequal(info.independent_measurement,false) && isequal(info.explicit_selection_required,true), ...
    'Residual:invalid_assumption_provenance','Invalid assumption source.');
hash = tool_sha256(strjoin(hashes,'|'),'text');
end
