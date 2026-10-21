function plot_step2_f1(folder,root,d,r,acquisition,thresholds,alarmTime)
% Draw only from saved measured data and residuals; preserve editable figures.
healthy = load(fullfile(root,'results','EXP-20261016-001','residuals.mat'), ...
    'residuals');
fig = figure('Name','F1位置偏置0.02mm复现','Visible','off', ...
    'Position',[80 50 1150 1000],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(4,1,'TileSpacing','compact');
nexttile;
sample = 1:200:numel(d.time_s);
plot(d.time_s(sample),d.x_ref_m(sample)*1e3,'--', ...
    d.time_s(sample),d.x_meas_m(sample)*1e3,'LineWidth',1);
grid on; ylabel('测量位置（mm）');
title('F1运行中位置偏置 +0.02 mm：1500 N，5 mm往返');
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
        legend('健康参考','本次F1','历史阈值','Location','eastoutside');
    end
end
xlabel('时间（s），仅显示有效运动残差');
saveBoth(fig,folder,'F1位置偏置0.02mm_健康对照与残差');
clear cleanup;

fig = figure('Name','F1报警与外载切换核对','Visible','off', ...
    'Position',[100 100 1100 750],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(2,1,'TileSpacing','compact');
nexttile;
plot(r.time_s,r.x_consistency_m*1e6,'b.-','LineWidth',1); hold on;
yline(thresholds(1)*1e6,'r--');
xline(0.03,'k:','评价端注入时刻');
xline(alarmTime,'m--','首次报警');
xlim([0.024 0.05]); grid on; ylabel('位置残差（μm）');
title('位置残差报警：沿用历史阈值，连续10个有效点');
nexttile;
native = acquisition.nativeSignals.get('external_force_known_N').Values;
input = acquisition.externalInput.get('ExternalForce');
mask = native.Time>=0.018 & native.Time<=0.021;
plot(native.Time(mask),native.Data(mask),'.-','LineWidth',1); hold on;
mask = d.time_s>=0.018 & d.time_s<=0.021;
plot(d.time_s(mask),d.external_force_known_N(mask),'--','LineWidth',1);
stairs(input.Time,input.Data,'k:','LineWidth',1);
xlim([0.018 0.021]); ylim([-100 1600]); grid on;
ylabel('规定外载（N）'); xlabel('时间（s）');
title('外载切换：原生路由日志、对齐记录与输入节点阶梯示意');
legend('原生日志','5 μs对齐记录','输入节点按保持绘制', ...
    'Location','eastoutside');
saveBoth(fig,folder,'F1位置偏置0.02mm_报警时刻与外载切换核对');
end

function saveBoth(fig,folder,name)
savefig(fig,fullfile(folder,[name '.fig']));
exportgraphics(fig,fullfile(folder,[name '.png']),'Resolution',160);
end
