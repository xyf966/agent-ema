function plot_step5_f1_gradual(folder,d,r,alarms,evaluation)
% Evaluation profile is for researcher QA only, never a diagnosis-tool input.
fig = figure('Name','F1代表性渐变复现','Visible','off', ...
    'Position',[80 50 1150 1000],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(4,1,'TileSpacing','compact');
nexttile;
sample = 1:200:numel(d.time_s);
plot(d.time_s(sample),d.x_ref_m(sample)*1e3,'--', ...
    d.time_s(sample),d.x_meas_m(sample)*1e3,'LineWidth',1);
grid on; ylabel('测量位置（mm）');
title('F1代表性渐变：0.03–0.18 s增至0.02 mm，正常外载1500 N');
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
saveBoth(fig,folder,'F1代表性渐变_观测与残差');
clear cleanup;
fig = figure('Name','F1渐变波形与报警核对','Visible','off', ...
    'Position',[100 80 1100 780],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(2,1,'TileSpacing','compact');
nexttile;
plot(evaluation.time_s,evaluation.expectedBias_m*1e6,'k--'); hold on;
plot(evaluation.time_s,evaluation.actualBias_m*1e6,'b','LineWidth',1);
plot(r.time_s,r.x_consistency_m*1e6,'Color',[0.8 0.3 0.1]);
xlim([0 0.22]); grid on; ylabel('偏置/位置残差（μm）');
title('生成端波形复验：注入真值仅用于评价，不进入检测器');
legend('设定渐变','实际注入','位置残差','Location','eastoutside');
nexttile;
mask = r.time_s>=0.025 & r.time_s<=0.055;
plot(r.time_s(mask),r.x_consistency_m(mask)*1e6,'b.-','LineWidth',1); hold on;
yline(alarms.Threshold(1)*1e6,'r--');
xline(0.03,'k:','评价端渐变起点');
xline(alarms.FirstExceed_s(1),'Color',[0.2 0.6 0.2], ...
    'LineStyle',':','Label','首次越阈值');
xline(alarms.FirstAlarm_s(1),'m--','位置首次报警');
xlim([0.025 0.055]); grid on; ylabel('位置残差（μm）'); xlabel('时间（s）');
title('报警局部：沿用历史阈值、连续10个有效输出点');
saveBoth(fig,folder,'F1代表性渐变_波形复验与报警时刻');
end

function saveBoth(fig,folder,name)
savefig(fig,fullfile(folder,[name '.fig']));
exportgraphics(fig,fullfile(folder,[name '.png']),'Resolution',160);
end
