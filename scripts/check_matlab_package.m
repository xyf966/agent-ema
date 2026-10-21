% Loading and syntax checks only. This script does not compile or simulate.
packageRoot = fileparts(fileparts(mfilename('fullpath')));
addpath(packageRoot);
packageReport = struct('matlabVersion',version,'loadAndSyntaxPassed',false, ...
    'compiled',false,'simulationExecuted',false,'error','');
try
    packageReport.products = ver;
    packageVariants = {'fixed','gradual'};
    packageItems = struct([]);
    for packageIndex = 1:numel(packageVariants)
        packageState = start_ema_agent_paper(packageVariants{packageIndex});
        assert(strcmpi(get_param(packageState.modelName,'FileName'), ...
            packageState.modelPath),'Paper:ModelPath','Unexpected loaded model.');
        packageFolder = fileparts(packageState.modelPath);
        packageInit = fullfile(packageFolder,'paper_init_unified_ema.m');
        packageNominal = readPaperNominal(packageInit);
        assert(packageNominal.fault.activeMode==0, ...
            'Paper:NominalMode','Nominal mode must be healthy.');
        packageScripts = dir(fullfile(packageFolder,'*.m'));
        packageIssues = struct([]);
        for packageScriptIndex = 1:numel(packageScripts)
            packageScript = fullfile(packageScripts(packageScriptIndex).folder, ...
                packageScripts(packageScriptIndex).name);
            packageMessages = checkcode(packageScript,'-id');
            packageIssues(packageScriptIndex).file = packageScripts(packageScriptIndex).name;
            packageIssues(packageScriptIndex).messages = packageMessages;
            if ~isempty(packageMessages)
                assert(~any(strcmp({packageMessages.id},'PARSE')), ...
                    'Paper:Syntax','MATLAB parser reported a syntax error.');
            end
        end
        packageItems(packageIndex).variant = packageVariants{packageIndex};
        packageItems(packageIndex).modelPath = packageState.modelPath;
        packageItems(packageIndex).loaded = true;
        packageItems(packageIndex).nominalInitializationPassed = true;
        packageItems(packageIndex).codeAnalyzer = packageIssues;
        close_system(packageState.modelName,0);
    end
    packageReport.variants = packageItems;
    packageReport.loadAndSyntaxPassed = true;
catch packageError
    packageReport.error = getReport(packageError,'extended','hyperlinks','off');
end
packageReportPath = fullfile(packageRoot,'provenance','matlab_load_check.json');
packageHandle = fopen(packageReportPath,'w','n','UTF-8');
assert(packageHandle>=0,'Paper:Report','Unable to open the package check report.');
fprintf(packageHandle,'%s',jsonencode(packageReport,'PrettyPrint',true));
fclose(packageHandle);
disp(packageReport);
assert(packageReport.loadAndSyntaxPassed,'Paper:LoadCheckFailed', ...
    'Package check failed. See provenance/matlab_load_check.json.');

function nominal = readPaperNominal(initializer)
run(initializer);
nominal = ema;
end
