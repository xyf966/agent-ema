function plot_healthy_replay(folder,d,r,thresholds)
% Plot saved observations/residuals without rerunning the physical model.
% Save actual MATLAB graphics objects so curves and labels remain editable.
fig = figure('Name','EMA healthy 1500 N replay','Visible','off', ...
    'Position',[50 50 1150 1050],'Color','w');
cleanup = onCleanup(@() close(fig));
tiledlayout(5,1,'TileSpacing','compact');
nexttile;
sample = 1:200:numel(d.time_s);
plot(d.time_s(sample),d.x_ref_m(sample)*1e3,'--', ...
    d.time_s(sample),d.x_meas_m(sample)*1e3,'LineWidth',1);
ylabel('Position (mm)'); legend('Command','Measured','Location','eastoutside');
title('Healthy replay: 1500 N prescribed bench load, 5 mm round trip'); grid on;
fields = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
scales = [1e6 1 1];
labels = {'Position residual (um)','Current sum (A)','Torque residual (N m)'};
for j = 1:3
    nexttile;
    plot(r.time_s,r.(fields{j})*scales(j),'Color',[0.65 0.65 0.65]); hold on;
    v = r.(fields{j})*scales(j); v(~r.motion_valid) = NaN;
    plot(r.time_s,v,'b','LineWidth',1);
    yline(thresholds(j)*scales(j),'r--');
    yline(-thresholds(j)*scales(j),'r--');
    ylabel(labels{j}); grid on;
    if j==1
        legend('All points','Valid motion','Historical threshold', ...
            'Location','eastoutside');
    end
end
nexttile;
stairs(r.time_s,double(r.motion_valid),'LineWidth',1);
ylim([-0.1 1.2]); ylabel('Motion valid'); xlabel('Time (s)'); grid on;
savefig(fig,fullfile(folder,'健康1500N_往返响应与残差复现.fig'));
if ~isfile(fullfile(folder,'健康1500N_往返响应与残差复现.png'))
    exportgraphics(fig,fullfile(folder,'健康1500N_往返响应与残差复现.png'),'Resolution',160);
end
end
