function observations = select_public_observations(source,policy)
% Pure positive-list selection: never copy a source structure wholesale.
assert(isstruct(source) && isscalar(source),'Paper:ObservationType', ...
    'Observation input must be a scalar structure.');
names = cellstr(string(policy.observation_fields));
observations = struct();
for k = 1:numel(names)
    name = names{k};
    assert(isfield(source,name),'Paper:MissingChannel','Required channel missing.');
    value = source.(name);
    assert(isa(value,'double') && isreal(value) && ismatrix(value) && ...
        all(isfinite(value(:))),'Paper:ChannelType','Invalid numeric channel.');
    observations.(name) = value;
end
t = observations.time_s;
assert(size(t,2)==1 && numel(t)>2,'Paper:TimeShape','Invalid time vector.');
assert(all(diff(t)>0) && ...
    max(abs(diff(t)-policy.input_sample_time_s))<policy.time_tolerance_s, ...
    'Paper:SampleTime','Invalid sample grid.');
for k = 1:numel(names)
    assert(isequal(size(observations.(names{k})), ...
        [numel(t),policy.observation_widths(k)]), ...
        'Paper:ChannelShape','Channel dimensions do not match the contract.');
end
end
