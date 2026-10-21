function r = residual_kernel_v1(d, nominal)
% EMA-DIAG-1.0. Only measured/command signals and nominal parameters enter.
% Uniform 5 us input; trailing 10 ms windows. No fault labels or truth inputs.
t = d.time_s(:);
dt = median(diff(t));
assert(numel(t) > 2 && all(diff(t) > 0) && ...
    max(abs(diff(t)-dt)) < 1e-10, 'Diagnosis:Time', ...
    'Inputs must have a strictly increasing uniform time grid.');
assert(abs(dt-5e-6) < 1e-10, 'Diagnosis:SampleTime', ...
    'Version 1 uses 5 us samples before window integration.');
signals = [d.x_meas_m, d.omega_meas_radps, d.iabc_meas_A, ...
    d.id_meas_A, d.iq_meas_A, d.x_ref_m];
assert(size(signals,1) == numel(t) && all(isfinite(signals(:))), ...
    'Diagnosis:Inputs', 'Measured inputs must be finite and time aligned.');
assert(size(d.iabc_meas_A,2) == 3, 'Diagnosis:CurrentWidth', ...
    'Three independently measured phase currents are required.');
k = nominal.mechanics.screwLead_mPerRev / ...
    (2*pi*nominal.mechanics.gearRatio);
c = k/nominal.mechanics.efficiency;
velocity = k*d.omega_meas_radps;
friction = nominal.mechanics.coulombFriction_N*sign(velocity) + ...
    nominal.mechanics.viscousFriction_NsPerM*velocity;
torqueEstimate = 1.5*nominal.motor.polePairs * ...
    (nominal.motor.flux_Wb*d.iq_meas_A + ...
    (nominal.motor.Ld_H-nominal.motor.Lq_H).*d.id_meas_A.*d.iq_meas_A);
netTorque = torqueEstimate - ...
    nominal.motor.viscousDamping_NmsPerRad*d.omega_meas_radps-c*friction;
windowSamples = round(0.010/dt);
endIndex = (windowSamples+1:round(0.001/dt):numel(t))';
startIndex = endIndex-windowSamples;
duration = t(endIndex)-t(startIndex);
average = @(v) windowAverage(t,v,startIndex,endIndex,duration);
r.time_s = t(endIndex);
r.window_s = 0.010;
r.x_consistency_m = d.x_meas_m(endIndex)-d.x_meas_m(1) - ...
    k*integralAt(t,d.omega_meas_radps,endIndex);
r.phase_sum_A = average(sum(d.iabc_meas_A,2));
r.iq_mean_A = average(d.iq_meas_A);
r.iq_rms_A = sqrt(average(d.iq_meas_A.^2));
r.tracking_error_m = average(d.x_ref_m-d.x_meas_m);
r.omega_mean_radps = average(d.omega_meas_radps);
r.torque_uncompensated_Nm = average(netTorque) - ...
    nominal.motor.rotorInertia_kgm2 * ...
    (d.omega_meas_radps(endIndex)-d.omega_meas_radps(startIndex))./duration;
% Context is explicitly known bench load, never MechanicalLoadTorque truth.
if d.loadKnown
    knownLoad = c*d.external_force_known_N + d.direct_torque_known_Nm;
    assert(numel(knownLoad) == numel(t) && all(isfinite(knownLoad)), ...
        'Diagnosis:KnownLoad', 'Known load must be finite and aligned.');
    r.torque_known_load_Nm = r.torque_uncompensated_Nm-average(knownLoad);
else
    r.torque_known_load_Nm = nan(size(r.time_s));
end
% Full window must remain away from zero speed; preserve invalid data for QA.
motionValid = movmin(double(abs(velocity)>0.005),[windowSamples,0]);
direction = sign(velocity);
directionMin = movmin(direction,[windowSamples,0]);
directionMax = movmax(direction,[windowSamples,0]);
r.motion_valid = motionValid(endIndex)>0 & ...
    directionMin(endIndex)==directionMax(endIndex);
end

function value = integralAt(t,signal,index)
integral = cumtrapz(t,signal);
value = integral(index);
end

function value = windowAverage(t,signal,first,last,duration)
integral = cumtrapz(t,signal);
value = (integral(last)-integral(first))./duration;
end
