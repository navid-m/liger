import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    Executable,
    State
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
let outputChannel: vscode.OutputChannel;
let statusBarItem: vscode.StatusBarItem | undefined;

function log(message: string, show: boolean = false) {
    const timestamp = new Date().toISOString();
    outputChannel.appendLine(`[${timestamp}] ${message}`);
    if (show) {
        outputChannel.show();
    }
}

function logError(message: string, error?: any) {
    const timestamp = new Date().toISOString();
    outputChannel.appendLine(`[${timestamp}] ERROR: ${message}`);
    if (error) {
        outputChannel.appendLine(`  ${error.toString()}`);
        if (error.stack) {
            outputChannel.appendLine(`  Stack: ${error.stack}`);
        }
    }
    outputChannel.show();
}

export function activate(context: vscode.ExtensionContext) {
    outputChannel = vscode.window.createOutputChannel('Liger Crystal');
    
    log('=== Liger Crystal Extension Activating ===');
    log(`VS Code version: ${vscode.version}`);
    log(`Extension path: ${context.extensionPath}`);
    log(`Workspace folders: ${vscode.workspace.workspaceFolders?.map(f => f.uri.fsPath).join(', ') || 'none'}`);
    
    outputChannel.show(true);

    statusBarItem = vscode.window.createStatusBarItem(
        vscode.StatusBarAlignment.Right,
        100
    );
    statusBarItem.text = '$(sync~spin) Liger';
    statusBarItem.tooltip = 'Liger Crystal Language Server is starting...';
    statusBarItem.command = 'liger.showOutputChannel';
    statusBarItem.show();
    context.subscriptions.push(statusBarItem);

    log('Registering commands...');
    
    const restartCommand = vscode.commands.registerCommand('liger.restartServer', async () => {
        log('Restart server command triggered');
        await restartServer(context);
    });
    context.subscriptions.push(restartCommand);
    log('  ✓ Registered: liger.restartServer');

    const showOutputCommand = vscode.commands.registerCommand('liger.showOutputChannel', () => {
        log('Show output channel command triggered');
        outputChannel.show();
    });
    context.subscriptions.push(showOutputCommand);
    log('  ✓ Registered: liger.showOutputChannel');

    const diagnosticsCommand = vscode.commands.registerCommand('liger.showDiagnostics', () => {
        showDiagnostics();
    });
    context.subscriptions.push(diagnosticsCommand);
    log('  ✓ Registered: liger.showDiagnostics');

    context.subscriptions.push(
        vscode.workspace.onDidOpenTextDocument((document) => {
            if (document.languageId === 'crystal') {
                log(`Crystal file opened: ${document.uri.fsPath}`);
                log(`  Language ID: ${document.languageId}`);
                log(`  Line count: ${document.lineCount}`);
            }
        })
    );

    const openCrystalFiles = vscode.workspace.textDocuments.filter(doc => doc.languageId === 'crystal');
    log(`Currently open Crystal files: ${openCrystalFiles.length}`);
    openCrystalFiles.forEach(doc => {
        log(`  - ${doc.uri.fsPath}`);
    });

    log('Starting language server...');
    startServer(context);

    log('=== Liger Crystal Extension Activated ===');
    log('Commands registered. You can now use:');
    log('  - Liger: Show Liger Output');
    log('  - Liger: Show Diagnostics Info');
    log('  - Liger: Restart Liger Language Server');
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}

async function startServer(context: vscode.ExtensionContext) {
    const config = vscode.workspace.getConfiguration('liger');
    const serverPath = config.get<string>('serverPath', 'liger');
    const traceLevel = config.get<string>('trace.server', 'off');

    log(`Configuration loaded:`);
    log(`  Server path: ${serverPath}`);
    log(`  Trace level: ${traceLevel}`);
    log(`  Max problems: ${config.get('maxNumberOfProblems', 100)}`);
    log(`Attempting to start server: ${serverPath}`);

    const serverExecutable: Executable = {
        command: serverPath,
        args: [],
        options: {
            env: process.env
        }
    };

    log(`Server executable configured:`);
    log(`  Command: ${serverExecutable.command}`);
    log(`  Args: ${JSON.stringify(serverExecutable.args)}`);

    const serverOptions: ServerOptions = serverExecutable;
    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            { scheme: 'file', language: 'crystal' },
            { scheme: 'untitled', language: 'crystal' }
        ],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/*.cr')
        },
        outputChannel: outputChannel,
        traceOutputChannel: outputChannel,
        revealOutputChannelOn: 4,
        initializationOptions: {
            maxNumberOfProblems: config.get('maxNumberOfProblems', 100)
        }
    };

    log(`Client options configured:`);
    log(`  Document selector: ${JSON.stringify(clientOptions.documentSelector)}`);
    log(`  File watcher pattern: **/*.cr`);
    log('Creating LanguageClient instance...');
    client = new LanguageClient(
        'ligerCrystal',
        'Liger Crystal Language Server',
        serverOptions,
        clientOptions
    );

    client.onDidChangeState((event) => {
        log(`Client state changed: ${State[event.oldState]} -> ${State[event.newState]}`);
        
        if (statusBarItem) {
            if (event.newState === State.Running) {
                statusBarItem.text = '$(check) Liger';
                statusBarItem.tooltip = 'Liger Crystal Language Server is running';
                statusBarItem.backgroundColor = undefined;
            } else if (event.newState === State.Starting) {
                statusBarItem.text = '$(sync~spin) Liger';
                statusBarItem.tooltip = 'Liger Crystal Language Server is starting...';
                statusBarItem.backgroundColor = undefined;
            } else {
                statusBarItem.text = '$(x) Liger';
                statusBarItem.tooltip = 'Liger Crystal Language Server stopped';
                statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
            }
            statusBarItem.show();
        }
    });

    try {
        log('Starting language client...');
        await client.start();
        log('✓ Liger language server started successfully');
        log(`Client state: ${State[client.state]}`);
        
        if (statusBarItem) {
            statusBarItem.text = '$(check) Liger';
            statusBarItem.tooltip = 'Liger Crystal Language Server is running';
            statusBarItem.show();
        }

        log('Server capabilities:');
        const capabilities = client.initializeResult?.capabilities;
        if (capabilities) {
            log(`  Text document sync: ${capabilities.textDocumentSync}`);
            log(`  Hover provider: ${capabilities.hoverProvider}`);
            log(`  Completion provider: ${!!capabilities.completionProvider}`);
            log(`  Definition provider: ${capabilities.definitionProvider}`);
            log(`  References provider: ${capabilities.referencesProvider}`);
            log(`  Rename provider: ${!!capabilities.renameProvider}`);
            log(`  Document symbol provider: ${capabilities.documentSymbolProvider}`);
            log(`  Workspace symbol provider: ${capabilities.workspaceSymbolProvider}`);
        } else {
            logError('No server capabilities received!');
        }

        log('Testing server connection...');
        setTimeout(async () => {
            const activeEditor = vscode.window.activeTextEditor;
            if (activeEditor) {
                log(`Active document: ${activeEditor.document.uri.fsPath}`);
                log(`  Language ID: ${activeEditor.document.languageId}`);
                log(`  Is Crystal: ${activeEditor.document.languageId === 'crystal'}`);
                log(`  Version: ${activeEditor.document.version}`);
                
                if (activeEditor.document.languageId !== 'crystal') {
                    log(`  Note: Expected 'crystal' but got '${activeEditor.document.languageId}'`);
                    log(`  File extension: ${path.extname(activeEditor.document.uri.fsPath)}`);
                }
            } else {
                log('No active editor window');
            }
        }, 1000);

    } catch (error) {
        logError('Failed to start Liger language server', error);
        
        if (statusBarItem) {
            statusBarItem.text = '$(x) Liger';
            statusBarItem.tooltip = 'Liger Crystal Language Server failed to start';
            statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
            statusBarItem.show();
        }
        
        const errorMessage = error instanceof Error ? error.message : String(error);
        vscode.window.showErrorMessage(
            `Failed to start Liger language server. Make sure 'liger' is installed and in your PATH. Error: ${errorMessage}`,
            'Show Output',
            'Configure Path'
        ).then(selection => {
            if (selection === 'Show Output') {
                outputChannel.show();
            } else if (selection === 'Configure Path') {
                vscode.commands.executeCommand('workbench.action.openSettings', 'liger.serverPath');
            }
        });
    }
}

async function restartServer(context: vscode.ExtensionContext) {
    log('=== Restarting Liger Language Server ===');
    
    if (client) {
        log('Stopping existing client...');
        await client.stop();
        client = undefined;
        log('Client stopped');
    }

    log('Starting new server instance...');
    await startServer(context);
    
    vscode.window.showInformationMessage('Liger language server restarted');
    log('=== Server Restart Complete ===');
}

function showDiagnostics() {
    log('=== Liger Diagnostics ===');
    
    // Client state
    if (client) {
        log(`Client exists: Yes`);
        log(`Client state: ${State[client.state]}`);
        log(`Client ID: ${client.clientOptions.documentSelector}`);
    } else {
        log(`Client exists: No`);
    }
    
    // Active document
    const activeEditor = vscode.window.activeTextEditor;
    if (activeEditor) {
        const doc = activeEditor.document;
        log(`Active document:`);
        log(`  URI: ${doc.uri.toString()}`);
        log(`  Path: ${doc.uri.fsPath}`);
        log(`  Language ID: ${doc.languageId}`);
        log(`  Is Crystal: ${doc.languageId === 'crystal'}`);
        log(`  Line count: ${doc.lineCount}`);
        log(`  Is dirty: ${doc.isDirty}`);
        log(`  Version: ${doc.version}`);
    } else {
        log(`No active document`);
    }
    
    // Configuration
    const config = vscode.workspace.getConfiguration('liger');
    log(`Configuration:`);
    log(`  Server path: ${config.get('serverPath')}`);
    log(`  Trace level: ${config.get('trace.server')}`);
    log(`  Diagnostics enabled: ${config.get('enableDiagnostics')}`);
    log(`  Completion enabled: ${config.get('enableCompletion')}`);
    log(`  Hover enabled: ${config.get('enableHover')}`);
    
    // Workspace
    log(`Workspace:`);
    if (vscode.workspace.workspaceFolders) {
        vscode.workspace.workspaceFolders.forEach((folder, i) => {
            log(`  Folder ${i + 1}: ${folder.uri.fsPath}`);
        });
    } else {
        log(`  No workspace folders`);
    }
    
    // Crystal files in workspace
    vscode.workspace.findFiles('**/*.cr', '**/node_modules/**', 10).then(files => {
        log(`Crystal files found (max 10):`);
        if (files.length === 0) {
            log(`  None`);
        } else {
            files.forEach(file => {
                log(`  ${file.fsPath}`);
            });
        }
    });
    
    log('=== End Diagnostics ===');
    outputChannel.show();
}
