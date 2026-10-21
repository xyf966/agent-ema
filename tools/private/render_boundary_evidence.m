function render_boundary_evidence(o,r,alarms,caseId,bundleId,mode,pngPath,figPath)
% Scientific overview from approved observations, residuals, and detector output.
f = figure('Visible','off','Color','w','Position',[100 80 1180 1050], ...
    'Name','匿名案例证据概览','NumberTitle','off','ToolBar','none','MenuBar','none');
cleanup = onCleanup(@() close(f));
f.UserData = struct('case_id',caseId,'residual_evidence_id',bundleId,'plot_version','EMA-BOUNDARY-PLOT-1.0');
layout = tiledlayout(f,4,1,'TileSpacing','compact','Padding','compact');
title(layout,['观测与残差证据 | ' caseId],'Interpreter','none','FontSize',13);
subtitle(layout,'灰区：无效运动点（不参与检测）；橙色竖线：首次连续10点报警。报警不等于故障确诊。', ...
    'FontName','Microsoft YaHei','FontSize',10);
ax = nexttile(layout); hold(ax,'on');
index = unique([1:200:numel(o.time_s),numel(o.time_s)]);
plot(ax,o.time_s(index),o.x_ref_m(index)*1000,'--','Color',[0.4 0.4 0.4], ...
    'DisplayName','位置指令','Tag','x_ref_m');
plot(ax,o.time_s(index),o.x_meas_m(index)*1000,'Color',[0 .35 .7], ...
    'DisplayName','测量位置','Tag','x_meas_m');
ylabel(ax,'位置 / mm'); title(ax,'(a) 观测概览（仅本面板按200点抽样显示）');
legend(ax,'Location','northeast','FontSize',9); finishAxis(ax,o.time_s);
names = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
labels = {'位置一致性残差 / μm','三相电流和 / A','转矩平衡残差 / N·m'};
titles = {'(b) 位置—速度一致性','(c) 三相电流和','(d) 转矩平衡（显式负载补偿假设）'};
scales = [1e6 1 1];
for k = 1:3
    ax = nexttile(layout); hold(ax,'on');
    field = names{k}; channel = alarms.result.channels(k);
    if isfield(r,field)
        values = r.(field)*scales(k); values(~r.motion_valid) = NaN;
        plot(ax,r.time_s,values,'Color',[0 .35 .7],'LineWidth',1, ...
            'Tag',field,'DisplayName','有效运动残差');
        th = channel.threshold*scales(k);
        yline(ax,th,'--','Color',[.8 .15 .15],'Tag',['threshold_' field], ...
            'DisplayName',sprintf('阈值 ±%.3g',th));
        yline(ax,-th,'--','Color',[.8 .15 .15],'HandleVisibility','off', ...
            'Tag',['threshold_negative_' field]);
        if ~isempty(channel.first_alarm_s)
            xline(ax,channel.first_alarm_s,'-','Color',[.9 .45 0],'LineWidth',1.2, ...
                'Tag',['alarm_' field],'DisplayName',sprintf('首次报警 %.3f s',channel.first_alarm_s));
        end
        if ~channel.detector_executed
            text(ax,.02,.85,'未执行报警检测：当前条件或连续有效点不足', ...
                'Units','normalized','FontName','Microsoft YaHei','FontSize',9);
        end
        shadeInvalid(ax,r.time_s,r.motion_valid);
        legend(ax,'Location','northeast','FontSize',9);
    else
        text(ax,.5,.5,'该残差不可用：缺少所需条件；未绘制波形、阈值或报警', ...
            'Units','normalized','HorizontalAlignment','center','FontName','Microsoft YaHei');
        ylim(ax,[-1 1]); yticks(ax,[]);
        if k==3 && strcmp(mode,'none'), titles{k} = '(d) 补偿转矩残差：未选择负载补偿假设'; end
    end
    ylabel(ax,labels{k}); title(ax,titles{k}); finishAxis(ax,o.time_s);
end
xlabel(ax,'时间 / s');
if ismember(mode,{'prescribed_command','recorded_assumption'})
    note = '补偿依据为规定负载指令，非独立负载测量。阈值仅用于已有理想仿真基线，未验证实物或噪声条件。';
else
    note = '未选择负载补偿假设；不将补偿阈值用于未补偿转矩。阈值仅用于已有理想仿真基线。';
end
if strcmp(mode,'recorded_assumption')
    note = 'Compensation: separately recorded diagnostic assumption, not actual load measurement. Ideal-simulation thresholds only.';
end
xlabel(layout,note,'FontName','Microsoft YaHei','FontSize',10);
drawnow;
savefig(f,figPath);
exportgraphics(f,pngPath,'Resolution',180);
end

function finishAxis(ax,t)
grid(ax,'on'); xlim(ax,[t(1) t(end)]);
set(ax,'FontName','Microsoft YaHei','FontSize',10,'Layer','top');
end

function shadeInvalid(ax,t,valid)
first = find(diff([false;~valid(:)])==1);
last = find(diff([~valid(:);false])==-1);
limits = ylim(ax);
for j = 1:numel(first)
    a = max(t(1),t(first(j))-.0005); b = min(t(end),t(last(j))+.0005);
    p = patch(ax,[a b b a],[limits(1) limits(1) limits(2) limits(2)], ...
        [.85 .85 .85],'EdgeColor','none','FaceAlpha',.4, ...
        'HandleVisibility','off','Tag','invalid_motion');
    uistack(p,'bottom');
end
ylim(ax,limits);
end
