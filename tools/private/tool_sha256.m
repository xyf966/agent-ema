function value = tool_sha256(input,kind)
digest = java.security.MessageDigest.getInstance('SHA-256');
if strcmp(kind,'text')
    digest.update(typecast(unicode2native(input,'UTF-8'),'int8'));
elseif strcmp(kind,'file')
    handle = fopen(input,'rb');
    assert(handle>=0,'Residual:read_failed','Cannot read approved file.');
    cleanup = onCleanup(@() fclose(handle));
    while ~feof(handle)
        digest.update(typecast(fread(handle,1024*1024,'*uint8'),'int8'));
    end
else
    error('Residual:internal_execution_error','Invalid hashing mode.');
end
value = lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end
