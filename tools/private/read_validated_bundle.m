function [residuals,parent] = read_validated_bundle(id,release,manifest,derived,algorithm)
% Revalidate against approved numerical inputs; do not trust editable metadata alone.
require(~isempty(regexp(id,'^BUNDLE-[0-9a-f]{64}$','once')),'invalid_residual_evidence_id');
base = char(java.io.File(derived).getCanonicalPath());
folder = char(java.io.File(fullfile(derived,id)).getCanonicalPath());
require(startsWith(lower(folder),lower([base filesep])),'access_denied');
jsonPath = canonicalChild(folder,'metadata.json');
matPath = canonicalChild(folder,'residuals.mat');
require(isfile(jsonPath) && isfile(matPath),'unknown_residual_evidence');
meta = jsondecode(fileread(jsonPath));
require(hasKeys(meta,{'case_id','group_id','bundle_id','input_hash','tool_version', ...
    'algorithm_version','algorithm_hash','parameter_version','load_assumption', ...
    'compensation_available','independent_load_supported','artifact_sha256'}),'invalid_evidence_metadata');
require(ischar(meta.case_id) && ~isempty(regexp(meta.case_id,'^CASE-[0-9a-f]{32}$','once')) && ...
    strcmp(meta.bundle_id,id) && strcmp(['BUNDLE-' meta.input_hash],id) && ...
    ismember(meta.load_assumption,{'none','prescribed_command'}),'invalid_evidence_metadata');
require(strcmp(tool_sha256(matPath,'file'),meta.artifact_sha256),'evidence_integrity_mismatch');
% expectedBundleId prevents writes or creation under a mismatched or missing identity.
parent = compute_residual_core(meta.case_id,meta.load_assumption,release,manifest,derived,algorithm,id);
if ~isfield(parent.result,'bundle_id')
    if strcmp(parent.status,'insufficient_data')
        error('Anomaly:residual_source_unavailable','Residual source unavailable.');
    end
    error('Anomaly:residual_validation_failed','Residual validation failed.');
end
require(strcmp(parent.result.bundle_id,id) && ...
    strcmp(parent.result.artifact_sha256,meta.artifact_sha256),'evidence_integrity_mismatch');
saved = load(matPath,'residuals');
require(hasKeys(saved,{'residuals'}) && ...
    strcmp(tool_sha256(matPath,'file'),parent.result.artifact_sha256),'evidence_integrity_mismatch');
residuals = saved.residuals;
end

function path = canonicalChild(folder,name)
path = char(java.io.File(fullfile(folder,name)).getCanonicalPath());
require(startsWith(lower(path),lower([folder filesep])),'access_denied');
end

function yes = hasKeys(value,names)
yes = isstruct(value) && isscalar(value) && ...
    isequal(sort(string(fieldnames(value))),sort(string(names(:))));
end

function require(yes,code)
assert(isscalar(yes) && yes,['Anomaly:' code],'Evidence check failed.');
end
