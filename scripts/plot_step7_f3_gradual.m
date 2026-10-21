function plot_step7_f3_gradual(folder,d,r,alarms,evaluation)
% Research QA only: injected resistance is never a diagnosis-tool observation.
fig = figure('Name','F3代表性渐变复现','Visible','off', ...
    'Position',[80 50 1150 1000],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(4,1,'TileSpacing','compact');
nexttile;
sample = 1:200:numel(d.time_s);
plot(d.time_s(sample),d.x_ref_m(sample)*1e3,'--', ...
    d.time_s(sample),d.x_meas_m(sample)*1e3,'LineWidth',1);
grid on; ylabel('测量位置（mm）');
title('F3代表性渐变：0.03–0.18 s增至300 N，正常外载1500 N');
legend('位置指令','测量位置','Location','eastoutside');
fields = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
scales = [1e6 1 1];
labels = {'位置残差（μm）','电流和（A）','补偿转矩残差（N·m）'};
for j = 1:3
    nexttile;
    plot(r.time_s,r.(fields{j})*scales(j),'Color',[0.65 0.65 0.65]); hold on;
    values = r.(fields{j})*scales(j); values(~r.motion_valid) = NaN;
    plot(r.time_s,values,'b','LineWidth',1);
    yline(alarms.Threshold(j)*scales(j),'r--');
    yline(-alarms.Threshold(j)*scales(j),'r--');
    ylabel(labels{j}); grid on;
    if j==1
        legend('全部输出点','有效运动点','历史阈值','Location','eastoutside');
    end
end
xlabel('时间（s）');
saveBoth(fig,folder,'F3代表性渐变_观测与残差');
clear cleanup;
fig = figure('Name','F3渐变波形与报警核对','Visible','off', ...
    'Position',[100 80 1100 780],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(2,1,'TileSpacing','compact');
nexttile;
plot(evaluation.time_s,evaluation.expectedResistance_N,'k--'); hold on;
plot(evaluation.time_s,evaluation.actualResistance_N,'b','LineWidth',1);
xlim([0 0.22]); ylim([-10 330]); grid on; ylabel('附加阻力幅值（N）');
title('生成端波形复验：方向处理前的阻力幅值，仅用于评价');
legend('设定渐变','实际幅值','Location','eastoutside');
nexttile;
mask = r.time_s>=0.025 & r.time_s<=0.07;
values = r.torque_known_load_Nm(mask);
values(~r.motion_valid(mask)) = NaN;
plot(r.time_s(mask),values,'b.-','LineWidth',1); hold on;
yline(alarms.Threshold(3),'r--'); yline(-alarms.Threshold(3),'r--');
xline(0.03,'k:','评价端渐变起点');
if isfinite(alarms.FirstExceed_s(3))
    xline(alarms.FirstExceed_s(3),'Color',[0.2 0.6 0.2], ...
        'LineStyle',':','Label','首次越阈值');
end
if isfinite(alarms.FirstAlarm_s(3))
    xline(alarms.FirstAlarm_s(3),'m--','转矩首次报警');
end
xlim([0.025 0.07]); grid on; ylabel('补偿转矩残差（N·m）'); xlabel('时间（s）');
title('转矩主通道：尾随10 ms窗口、连续10个有效输出点');
saveBoth(fig,folder,'F3代表性渐变_波形复验与报警时刻');
end

function saveBoth(fig,folder,name)
savefig(fig,fullfile(folder,[name '.fig']));
exportgraphics(fig,fullfile(folder,[name '.png']),'Resolution',160);
end
