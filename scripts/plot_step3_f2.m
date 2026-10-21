function plot_step3_f2(folder,root,d,r,acquisition,thresholds,alarmTimes)
% Research figures from measured data and residuals; no new simulation.
healthy = load(fullfile(root,'results','EXP-20261016-001','residuals.mat'), ...
    'residuals');
fig = figure('Name','F2电流偏置1A复现','Visible','off', ...
    'Position',[80 50 1150 1000],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(4,1,'TileSpacing','compact');
nexttile;
sample = 1:200:numel(d.time_s);
plot(d.time_s(sample),d.x_ref_m(sample)*1e3,'--', ...
    d.time_s(sample),d.x_meas_m(sample)*1e3,'LineWidth',1);
grid on; ylabel('测量位置（mm）');
title('F2运行中A相电流偏置 +1 A：1500 N，5 mm往返');
legend('位置指令','测量位置','Location','eastoutside');
fields = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
scales = [1e6 1 1];
labels = {'位置残差（μm）','电流和（A）','补偿转矩残差（N·m）'};
for j = 1:3
    nexttile;
    a = healthy.residuals.(fields{j})*scales(j);
    a(~healthy.residuals.motion_valid) = NaN;
    b = r.(fields{j})*scales(j); b(~r.motion_valid) = NaN;
    plot(healthy.residuals.time_s,a,'Color',[0.5 0.5 0.5]); hold on;
    plot(r.time_s,b,'b','LineWidth',1);
    yline(thresholds(j)*scales(j),'r--');
    yline(-thresholds(j)*scales(j),'r--');
    ylabel(labels{j}); grid on;
    if j==1
        legend('健康参考','本次F2','历史阈值','Location','eastoutside');
    end
end
xlabel('时间（s），仅显示有效运动残差');
saveBoth(fig,folder,'F2电流偏置1A_健康对照与残差');
clear cleanup;

fig = figure('Name','F2报警与转矩交叉响应','Visible','off', ...
    'Position',[100 40 1100 1000],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(3,1,'TileSpacing','compact');
nexttile;
native = acquisition.nativeSignals.get('iabc_meas_A').Values;
nativeData = reshape(native.Data,numel(native.Time),[]);
nativeMask = native.Time>=0.02 & native.Time<=0.08;
plot(native.Time(nativeMask),sum(nativeData(nativeMask,:),2), ...
    'Color',[0.6 0.6 0.6]); hold on;
plot(r.time_s,r.phase_sum_A,'b.-','LineWidth',1);
yline(thresholds(2),'r--');
xline(0.03,'k:','评价端注入时刻');
if isfinite(alarmTimes(2))
    xline(alarmTimes(2),'m--','电流首次报警');
end
xlim([0.02 0.08]); ylim([-0.1 1.15]); grid on;
ylabel('三相电流和（A）');
title('电流主响应：原生测量和与尾随10 ms残差');
legend('原生测量电流和','尾随窗口残差','历史阈值', ...
    'Location','eastoutside');
for panel = 1:2
    nexttile;
    bounds = [0.05 0.18];
    if panel==2
        bounds = [0.19 0.23];
    end
    healthyMask = healthy.residuals.time_s>=bounds(1) & ...
        healthy.residuals.time_s<=bounds(2);
    mask = r.time_s>=bounds(1) & r.time_s<=bounds(2);
    a = healthy.residuals.torque_known_load_Nm(healthyMask);
    a(~healthy.residuals.motion_valid(healthyMask)) = NaN;
    b = r.torque_known_load_Nm(mask);
    b(~r.motion_valid(mask)) = NaN;
    plot(healthy.residuals.time_s(healthyMask),a, ...
        'Color',[0.6 0.6 0.6]); hold on;
    plot(r.time_s(mask),b,'b.-','LineWidth',1);
    yline(thresholds(3),'r--'); yline(-thresholds(3),'r--');
    if panel==2 && isfinite(alarmTimes(3))
        xline(alarmTimes(3),'m--','转矩首次报警');
    end
    xlim(bounds); grid on; ylabel('补偿转矩残差（N·m）');
    if panel==1
        title('稳定去程窗口：转矩残差波动增大');
    else
        title('去程结束附近：同一F2案例也触发转矩报警');
        xlabel('时间（s），残差仅显示有效运动点');
    end
    legend('健康参考','本次F2','历史阈值','Location','eastoutside');
end
saveBoth(fig,folder,'F2电流偏置1A_报警时刻与转矩交叉响应');
end

function saveBoth(fig,folder,name)
savefig(fig,fullfile(folder,[name '.fig']));
exportgraphics(fig,fullfile(folder,[name '.png']),'Resolution',160);
end
