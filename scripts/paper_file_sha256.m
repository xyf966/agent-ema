function value = paper_file_sha256(path)
% Stream a file without modifying it; used by research export verification.
handle = fopen(path,'rb');
assert(handle>=0,'Paper:HashRead','Cannot open file for hashing.');
cleanup = onCleanup(@() fclose(handle));
digest = java.security.MessageDigest.getInstance('SHA-256');
while ~feof(handle)
    bytes = fread(handle,1024*1024,'*uint8');
    digest.update(typecast(bytes,'int8'));
end
value = lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end
