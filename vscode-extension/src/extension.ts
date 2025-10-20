import * as path from 'path';
import * as vscode from 'vscode';
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
    Executable
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
let outputChannel: vscode.OutputChannel;

export function activate(context: vscode.ExtensionContext) {
    outputChannel = vscode.window.createOutputChannel('Liger Crystal');
    outputChannel.appendLine('Liger Crystal extension activating...');

    // Register commands
    context.subscriptions.push(
        vscode.commands.registerCommand('liger.restartServer', async () => {
            await restartServer();
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('liger.showOutputChannel', () => {
            outputChannel.show();
        })
    );

    // Start the language server
    startServer(context);

    outputChannel.appendLine('Liger Crystal extension activated');
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

    outputChannel.appendLine(`Starting Liger language server: ${serverPath}`);

    // Server executable options
    const serverExecutable: Executable = {
        command: serverPath,
        args: [],
        options: {
            env: process.env
        }
    };

    const serverOptions: ServerOptions = serverExecutable;

    // Client options
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
        revealOutputChannelOn: 4, // Never automatically show
        initializationOptions: {
            maxNumberOfProblems: config.get('maxNumberOfProblems', 100)
        }
    };

    // Create the language client
    client = new LanguageClient(
        'ligerCrystal',
        'Liger Crystal Language Server',
        serverOptions,
        clientOptions
    );

    // Start the client (this will also launch the server)
    try {
        await client.start();
        outputChannel.appendLine('Liger language server started successfully');
        
        // Show status bar item
        const statusBarItem = vscode.window.createStatusBarItem(
            vscode.StatusBarAlignment.Right,
            100
        );
        statusBarItem.text = '$(check) Liger';
        statusBarItem.tooltip = 'Liger Crystal Language Server is running';
        statusBarItem.command = 'liger.showOutputChannel';
        statusBarItem.show();
        context.subscriptions.push(statusBarItem);

        // Update status on server state changes
        client.onDidChangeState((event) => {
            if (event.newState === 2) { // Running
                statusBarItem.text = '$(check) Liger';
                statusBarItem.tooltip = 'Liger Crystal Language Server is running';
            } else if (event.newState === 1) { // Starting
                statusBarItem.text = '$(sync~spin) Liger';
                statusBarItem.tooltip = 'Liger Crystal Language Server is starting...';
            } else { // Stopped
                statusBarItem.text = '$(x) Liger';
                statusBarItem.tooltip = 'Liger Crystal Language Server stopped';
            }
        });

    } catch (error) {
        const errorMessage = error instanceof Error ? error.message : String(error);
        outputChannel.appendLine(`Failed to start Liger language server: ${errorMessage}`);
        
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

async function restartServer() {
    outputChannel.appendLine('Restarting Liger language server...');
    
    if (client) {
        await client.stop();
        client = undefined;
    }

    // Get the context from the extension
    const context = (global as any).ligerContext as vscode.ExtensionContext;
    if (context) {
        await startServer(context);
    }

    vscode.window.showInformationMessage('Liger language server restarted');
}

// Store context globally for restart command
export function setContext(context: vscode.ExtensionContext) {
    (global as any).ligerContext = context;
}
