function plot_step6_f2_gradual(folder,d,r,alarms,evaluation)
% Injection data appears only in this researcher QA figure, not tool inputs.
fig = figure('Name','F2代表性渐变复现','Visible','off', ...
    'Position',[80 50 1150 1000],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(4,1,'TileSpacing','compact');
nexttile;
sample = 1:200:numel(d.time_s);
plot(d.time_s(sample),d.x_ref_m(sample)*1e3,'--', ...
    d.time_s(sample),d.x_meas_m(sample)*1e3,'LineWidth',1);
grid on; ylabel('测量位置（mm）');
title('F2代表性渐变：0.03–0.18 s增至1 A，正常外载1500 N');
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
saveBoth(fig,folder,'F2代表性渐变_观测与残差');
clear cleanup;

fig = figure('Name','F2渐变波形与交叉响应核对','Visible','off', ...
    'Position',[100 40 1100 1000],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(3,1,'TileSpacing','compact');
nexttile;
plot(evaluation.time_s,evaluation.expectedBias_A,'k--'); hold on;
plot(evaluation.time_s,evaluation.actualBias_A,'b','LineWidth',1);
plot(r.time_s,r.phase_sum_A,'Color',[0.8 0.3 0.1]);
xlim([0 0.22]); ylim([-0.05 1.1]); grid on; ylabel('偏置/电流和（A）');
title('生成端波形复验：注入真值仅用于评价，残差为尾随10 ms均值');
legend('设定渐变','实际注入','电流和残差','Location','eastoutside');
nexttile;
mask = r.time_s>=0.025 & r.time_s<=0.055;
plot(r.time_s(mask),r.phase_sum_A(mask),'b.-','LineWidth',1); hold on;
yline(alarms.Threshold(2),'r--');
xline(0.03,'k:','评价端渐变起点');
if isfinite(alarms.FirstExceed_s(2))
    xline(alarms.FirstExceed_s(2),'Color',[0.2 0.6 0.2], ...
        'LineStyle',':','Label','首次越阈值');
end
if isfinite(alarms.FirstAlarm_s(2))
    xline(alarms.FirstAlarm_s(2),'m--','电流首次报警');
end
xlim([0.025 0.055]); grid on; ylabel('电流和残差（A）');
title('电流主通道：沿用冻结阈值、连续10个有效输出点');
nexttile;
mask = r.time_s>=0.19 & r.time_s<=0.23;
values = r.torque_known_load_Nm(mask);
values(~r.motion_valid(mask)) = NaN;
plot(r.time_s(mask),values,'b.-','LineWidth',1); hold on;
yline(alarms.Threshold(3),'r--'); yline(-alarms.Threshold(3),'r--');
if isfinite(alarms.FirstExceed_s(3))
    xline(alarms.FirstExceed_s(3),'Color',[0.2 0.6 0.2], ...
        'LineStyle',':','Label','转矩首次越阈值');
end
if isfinite(alarms.FirstAlarm_s(3))
    xline(alarms.FirstAlarm_s(3),'m--','转矩首次报警');
end
xlim([0.19 0.23]); grid on; ylabel('补偿转矩残差（N·m）');
xlabel('时间（s）'); title('去程结束附近：同一F2渐变的转矩交叉响应');
saveBoth(fig,folder,'F2代表性渐变_波形报警与转矩交叉响应');
end

function saveBoth(fig,folder,name)
savefig(fig,fullfile(folder,[name '.fig']));
exportgraphics(fig,fullfile(folder,[name '.png']),'Resolution',160);
end
