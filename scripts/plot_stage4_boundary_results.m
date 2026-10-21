function report = plot_stage4_boundary_results()
% Research-side figures. Includes evaluation truth; never supply to Agent.
root = fileparts(fileparts(mfilename('fullpath')));
out = fullfile(root,'results','EXP-20261020-018');
assert(~isfile(fullfile(out,'research_figures_manifest.json')),'Paper:ExistingPlots','Preserve completed figure evidence.');
frozen = jsondecode(fileread(fullfile(root,'tools/registry/detector_thresholds_v1.json')));
healthy = load(fullfile(root,'results/EXP-20261016-001/residuals.mat'),'residuals');
f3 = load(fullfile(root,'results/EXP-20261016-004/residuals.mat'),'residuals');
manifest = struct([]);
for k=1:2
    runId = sprintf('EXP-20261020-%03d',15+k);
    folder = fullfile(root,'results',runId);
    saved = load(fullfile(folder,'residuals.mat'));
    o = load(fullfile(folder,'observations_aligned.mat'),'observations');
    d = o.observations; r = saved.residuals;
    fig = figure('Visible','off','Color','w','Position',[80 50 1200 1080], ...
        'ToolBar','none','MenuBar','none');
    cleanup = onCleanup(@() close(fig));
    fig.UserData = struct('research_only',true,'source_run',runId, ...
        'observation_sha256',paper_file_sha256(fullfile(folder,'observations_aligned.mat')), ...
        'residual_sha256',paper_file_sha256(fullfile(folder,'residuals.mat')));
    layout = tiledlayout(fig,4,1,'TileSpacing','compact','Padding','compact');
    ax = nexttile(layout); hold(ax,'on');
    index = 1:200:numel(d.time_s);
    if k==1
        name = 'F1启动已有恒定偏置_观测与残差边界验证';
        truth = load(fullfile(root,'data/evaluation_private',runId,'evaluation.mat'),'evaluation');
        plot(ax,d.time_s(index),truth.evaluation.actual_bias_m(index)*1e6,'LineWidth',1.3);
        ylabel(ax,'实际偏置 / μm'); ylim(ax,[19 21]);
        title(ax,'研究侧核对：测量位置−私有真实位置，自t=0恒定为20 μm');
    else
        name = '健康1800N_正确补偿与1500N假设及F3对照';
        plot(ax,d.time_s(index),d.external_force_known_N(index),'LineWidth',1.2,'DisplayName','生成端规定外载路由');
        assume = interp1(saved.assumption.time_s,saved.assumption.external_force_N,d.time_s,'linear');
        plot(ax,d.time_s(index),assume(index),'--','LineWidth',1.2,'DisplayName','诊断假设');
        ylabel(ax,'外载 / N'); legend(ax,'Location','eastoutside');
        title(ax,'生成端1800 N与诊断端1500 N分别记录；路由信号不是独立测量');
    end
    finish(ax);
    fields = {'x_consistency_m','phase_sum_A','torque_known_load_Nm'};
    scales = [1e6 1 1];
    labels = {'位置一致性 / μm','三相电流和 / A','补偿转矩 / N·m'};
    for j=1:3
        ax = nexttile(layout); hold(ax,'on');
        if k==1
            base = healthy.residuals.(fields{j})*scales(j); base(~healthy.residuals.motion_valid) = NaN;
            plot(ax,healthy.residuals.time_s,base,'Color',[.55 .55 .55],'DisplayName','健康1500 N参考');
        end
        values = r.(fields{j})*scales(j); values(~r.motion_valid) = NaN;
        plot(ax,r.time_s,values,'Color',[0 .35 .7],'LineWidth',1.2,'Tag',fields{j},'DisplayName','本次诊断残差');
        if k==2 && j==3
            correct = saved.correctResiduals.torque_known_load_Nm; correct(~saved.correctResiduals.motion_valid) = NaN;
            other = f3.residuals.torque_known_load_Nm; other(~f3.residuals.motion_valid) = NaN;
            plot(ax,r.time_s,correct,'Color',[.1 .6 .2],'DisplayName','按1800 N指令补偿');
            plot(ax,f3.residuals.time_s,other,'--','Color',[.7 .2 .7],'DisplayName','既有F3 300 N参考');
            xline(ax,.029,':','首次连续报警0.029 s','Color',[.85 .3 0],'HandleVisibility','off');
        end
        th = frozen.channels(j).threshold*scales(j);
        yline(ax,th,'r--','DisplayName','冻结阈值'); yline(ax,-th,'r--','HandleVisibility','off');
        ylabel(ax,labels{j}); legend(ax,'Location','eastoutside'); finish(ax);
    end
    title(layout,strrep(name,'_','：'),'Interpreter','none');
    xlabel(layout,'时间 / s。仅有效运动段参加检测；理想仿真阈值，未用于实物或噪声结论。');
    png = fullfile(folder,[name '.png']); editable = fullfile(folder,[name '.fig']);
    savefig(fig,editable); exportgraphics(fig,png,'Resolution',160);
    manifest = [manifest;struct('source_run',runId, ...
        'png',strrep(png(numel(root)+2:end),'\','/'),'png_sha256',paper_file_sha256(png), ...
        'fig',strrep(editable(numel(root)+2:end),'\','/'),'fig_sha256',paper_file_sha256(editable), ...
        'research_only_not_agent_input',true)]; %#ok<AGROW>
    clear cleanup;
end
report = struct('figures',manifest,'new_simulations',0,'agent_calls',0);
handle = fopen(fullfile(out,'research_figures_manifest.json'),'w','n','UTF-8');
cleanup = onCleanup(@() fclose(handle));
fprintf(handle,'%s',jsonencode(report,'PrettyPrint',true));
end

function finish(ax)
grid(ax,'on'); xlim(ax,[0 0.8]); set(ax,'FontName','Microsoft YaHei','FontSize',10);
end
