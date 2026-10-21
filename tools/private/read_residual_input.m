function [value,hash] = read_residual_input(release,manifestPath,kind)
% Private selector accepts two literal artifact roles, never a caller's path.
switch kind
    case 'parameters'
        name = 'parameters.json';
    case 'command'
        name = 'operating_context.mat';
    otherwise
        error('Residual:access_denied','Unapproved artifact role.');
end
manifest = jsondecode(fileread(manifestPath));
entry = manifest.files(strcmp({manifest.files.path},name));
assert(isscalar(entry),'Residual:access_denied','Artifact not approved.');
base = char(java.io.File(release).getCanonicalPath());
path = char(java.io.File(fullfile(release,name)).getCanonicalPath());
assert(startsWith(lower(path),lower([base filesep])),'Residual:access_denied','Outside release.');
assert(isfile(path),'Residual:missing_artifact','Artifact unavailable.');
hash = tool_sha256(path,'file');
assert(strcmp(hash,entry.sha256),'Residual:integrity_mismatch','Artifact changed.');
if strcmp(kind,'parameters')
    value = jsondecode(fileread(path));
else
    header = whos('-file',path);
    assert(isscalar(header) && strcmp(header.name,'command') && ...
        strcmp(header.class,'struct'),'Residual:unapproved_data_structure','Invalid command container.');
    value = load(path,'command');
    value = value.command;
end
end
