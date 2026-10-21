function report = test_stage2_export_boundary()
% Corrupt a PRIVATE COPY to ensure the read-back checker rejects bad exports.
root = fileparts(fileparts(mfilename('fullpath')));
private = fullfile(root,'data','evaluation_private','EXP-20261019-004');
release = fullfile(root,'data','agent_visible','observations_v1');
id = char(java.util.UUID.randomUUID());
fixture = fullfile(private,['validation_fixture_' id]);
assert(~isfolder(fixture));
[ok,message] = copyfile(release,fixture);
assert(ok,'%s',message);
catalog = jsondecode(fileread(fullfile(fixture,'catalog.json')));
caseFile = fullfile(fixture,catalog.cases(1).case_id,'observations.mat');
original = load(caseFile);
observations = original.observations;
observations.injected_secret = 1;
save(caseFile,'observations','-v7');
metaFile = fullfile(fixture,catalog.cases(1).case_id,'metadata.json');
meta = jsondecode(fileread(metaFile));
meta.observations_sha256 = paper_file_sha256(caseFile);
writeJson(metaFile,meta);
checks = rejected(fixture,private,'extra_truth_field_rejected','Paper:UnexpectedPublicFields');
% Restore the exact serialized file so its catalog hash also remains correct.
copyfile(fullfile(release,catalog.cases(1).case_id,'observations.mat'),caseFile,'f');
% For a numeric corruption, update the claimed checksum as an adversarial writer
% could. The source-value comparison must still detect the changed waveform.
observations = original.observations;
observations.x_meas_m(3) = observations.x_meas_m(3)+1;
save(caseFile,'observations','-v7');
meta = jsondecode(fileread(metaFile));
meta.observations_sha256 = paper_file_sha256(caseFile);
writeJson(metaFile,meta);
checks(end+1) = rejected(fixture,private,'numeric_tampering_rejected','Paper:ExportNumericMismatch');
copyfile(fullfile(release,catalog.cases(1).case_id,'observations.mat'),caseFile,'f');
copyfile(fullfile(release,catalog.cases(1).case_id,'metadata.json'),metaFile,'f');
contextFile = fullfile(fixture,'operating_context.json');
context = jsondecode(fileread(contextFile));
context.limitation = 'EXP-20261016-001 F1';
writeJson(contextFile,context);
checks(end+1) = rejected(fixture,private,'label_in_metadata_value_rejected','Paper:PublicTextLeak');
copyfile(fullfile(release,'operating_context.json'),contextFile,'f');
extra = fullfile(fixture,'unapproved.json');
writeJson(extra,struct('extra',true));
checks(end+1) = rejected(fixture,private,'extra_file_rejected','Paper:PublicFileSet');
% Remove only the single test file created immediately above, not a directory.
delete(extra);
baseline = verify_stage2_export(fixture,private);
assert(all([checks.passed]) && baseline.passed,'Paper:BoundaryTests','Boundary checks failed.');
report = struct('passed',true,'checks',checks,'restored_fixture_passed',baseline.passed, ...
    'public_release_modified',false,'fixture_directory', ...
    strrep(fixture(numel(root)+2:end),'\','/'));
writeJson(fullfile(root,'results','EXP-20261019-004','boundary_tests.json'),report);
fprintf('Passed %d export-boundary negative checks on a private copy.\n',numel(checks));
end

function item = rejected(fixture,private,name,expectedIdentifier)
identifier = '';
try
    verify_stage2_export(fixture,private);
catch issue
    identifier = issue.identifier;
end
item = struct('name',name,'expected_identifier',expectedIdentifier, ...
    'observed_identifier',identifier,'passed',strcmp(identifier,expectedIdentifier));
end

function writeJson(path,value)
handle = fopen(path,'w','n','UTF-8');
assert(handle>=0);
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(value,'PrettyPrint',true));
end
