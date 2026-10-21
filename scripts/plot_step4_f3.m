function plot_step4_f3(folder,root,d,r,thresholds,alarmTime)
% Plot saved measurements/residuals; preserve editable MATLAB graphics.
healthy = load(fullfile(root,'results','EXP-20261016-001','residuals.mat'), ...
    'residuals');
fig = figure('Name','F3附加阻力300N复现','Visible','off', ...
    'Position',[80 50 1150 1000],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(4,1,'TileSpacing','compact');
nexttile;
sample = 1:200:numel(d.time_s);
plot(d.time_s(sample),d.x_ref_m(sample)*1e3,'--', ...
    d.time_s(sample),d.x_meas_m(sample)*1e3,'LineWidth',1);
grid on; ylabel('测量位置（mm）');
title('F3运行中附加阻力300 N：正常外载1500 N，5 mm往返');
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
        legend('健康参考','本次F3','历史阈值','Location','eastoutside');
    end
end
xlabel('时间（s），仅显示有效运动残差');
saveBoth(fig,folder,'F3附加阻力300N_健康对照与残差');
clear cleanup;

fig = figure('Name','F3报警与外载补偿','Visible','off', ...
    'Position',[100 40 1100 950],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(3,1,'TileSpacing','compact');
nexttile;
mask = r.time_s>=0.025 & r.time_s<=0.06;
plot(r.time_s(mask),r.torque_known_load_Nm(mask),'b.-','LineWidth',1); hold on;
yline(thresholds(3),'r--'); yline(-thresholds(3),'r--');
xline(0.03,'k:','评价端注入时刻');
if isfinite(alarmTime)
    xline(alarmTime,'m--','转矩首次报警');
end
xlim([0.025 0.06]); grid on; ylabel('补偿转矩残差（N·m）');
title('转矩主响应与首次报警：尾随10 ms窗口、连续10个有效点');
for directionIndex = 1:2
    nexttile;
    bounds = [0.05 0.18]+0.5*(directionIndex-1);
    mask = r.time_s>=bounds(1) & r.time_s<=bounds(2) & r.motion_valid;
    plot(r.time_s(mask),r.torque_uncompensated_Nm(mask), ...
        'Color',[0.6 0.6 0.6]); hold on;
    plot(r.time_s(mask),r.torque_known_load_Nm(mask),'b','LineWidth',1);
    yline(0,'k:'); xlim(bounds); grid on;
    ylabel('转矩残差（N·m）');
    if directionIndex==1
        ylim([-0.01 0.18]);
        title('固定去程窗口：扣除规定正常外载后保留正向残差');
    else
        ylim([-0.18 0.01]);
        title('固定回程窗口：扣除规定正常外载后保留负向残差');
        xlabel('时间（s）');
    end
    legend('未补偿正常外载','已补偿正常外载','Location','eastoutside');
end
saveBoth(fig,folder,'F3附加阻力300N_报警时刻与外载补偿');
end

function saveBoth(fig,folder,name)
savefig(fig,fullfile(folder,[name '.fig']));
exportgraphics(fig,fullfile(folder,[name '.png']),'Resolution',160);
end
