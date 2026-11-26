using System;
using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using TMPro;
using UnityEngine;

public static class CypherAssist
{
    private const BindingFlags PrivateInstance = BindingFlags.NonPublic | BindingFlags.Instance;
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CypherAssist");
    private static float nextPoll;
    private static bool isSubmitting;
    private static Type terminalType;
    private static FieldInfo terminalFocus;
    private static FieldInfo terminalLocked;
    private static FieldInfo answerBuffer;
    private static FieldInfo answerLength;
    private static FieldInfo answerDisplay;
    private static MethodInfo resetAnswer;
    private static MethodInfo updateInput;

    public static void Initialize()
    {
        Application.runInBackground = true;
    }

    public static void Tick(object menus)
    {
        if (Time.realtimeSinceStartup < nextPoll)
            return;

        nextPoll = Time.realtimeSinceStartup + 0.25f;
        try
        {
            if (!Directory.Exists(DirectoryPath))
                return;

            foreach (string request in Directory.GetFiles(DirectoryPath, "*.request"))
            {
                if (Regex.IsMatch(Path.GetFileNameWithoutExtension(request), "^[0-9a-f]{32}$"))
                {
                    ProcessRequest(request, menus);
                    break;
                }
            }
        }
        catch (IOException error)
        {
            Debug.LogWarning("Cypher Assist: " + error.Message);
        }
        catch (UnauthorizedAccessException error)
        {
            Debug.LogWarning("Cypher Assist: " + error.Message);
        }
    }

    public static bool KeyPressed(KeyCode key)
    {
        return isSubmitting ? key == KeyCode.Return || key == KeyCode.KeypadEnter : Input.GetKeyDown(key);
    }

    public static bool KeyHeld(KeyCode key)
    {
        return !isSubmitting && Input.GetKey(key);
    }

    public static string InputText()
    {
        return isSubmitting ? string.Empty : Input.inputString;
    }

    private static void ProcessRequest(string path, object menus)
    {
        string claimedPath = Path.ChangeExtension(path, ".working");
        string resultPath = Path.ChangeExtension(path, ".result");
        try
        {
            File.Move(path, claimedPath);
        }
        catch (IOException)
        {
            return;
        }

        string result;
        try
        {
            if (new FileInfo(claimedPath).Length > 512)
                throw new ArgumentException("Request is too large.");

            string[] request = File.ReadAllLines(claimedPath);
            if (request.Length == 0 || request.Length > 2)
                throw new ArgumentException("Invalid request.");

            result = "ok\n" + Handle(request, menus, Path.ChangeExtension(path, ".png"));
        }
        catch (Exception error)
        {
            result = "error\n" + error.GetBaseException().Message;
        }

        string pendingResult = resultPath + ".tmp";
        File.WriteAllText(pendingResult, result);
        File.Move(pendingResult, resultPath);
        File.Delete(claimedPath);
    }

    private static string Handle(string[] request, object menus, string imagePath)
    {
        string command = request[0];
        if (command == "capture")
        {
            Application.CaptureScreenshot(imagePath);
            return "Screenshot requested.";
        }

        if (command != "status" && command != "type" && command != "submit" && command != "hint")
            throw new ArgumentException("Unknown Cypher Assist command.");

        UnityEngine.Object terminal = FindTerminal(menus);
        if (command == "status")
            return terminal != null ? "Active answer terminal." : "No active answer terminal.";

        if (terminal == null)
            throw new InvalidOperationException("Select an answer terminal in Cypher first.");
        if ((bool)terminalLocked.GetValue(terminal))
            throw new InvalidOperationException("The terminal is busy. Wait for its response.");

        string answer = command == "hint" ? "hint" : (request.Length == 2 ? request[1] : "");
        char[] buffer = (char[])answerBuffer.GetValue(terminal);
        TextMeshPro display = (TextMeshPro)answerDisplay.GetValue(terminal);
        if (buffer == null || display == null)
            throw new InvalidOperationException("The answer terminal is still initializing.");
        if (answer.Length == 0 || answer.Length > buffer.Length)
            throw new ArgumentException("Answer must contain 1 to " + buffer.Length + " characters.");
        foreach (char character in answer)
        {
            if (!char.IsLetterOrDigit(character) && !char.IsPunctuation(character))
                throw new ArgumentException("Cypher accepts letters, digits, and punctuation.");
        }

        resetAnswer.Invoke(terminal, null);
        buffer = (char[])answerBuffer.GetValue(terminal);
        answer.CopyTo(0, buffer, 0, answer.Length);
        answerLength.SetValue(terminal, answer.Length);
        display.text = new string(buffer).ToUpperInvariant();
        if (command == "type")
            return "Answer filled.";

        isSubmitting = true;
        try
        {
            updateInput.Invoke(terminal, null);
        }
        finally
        {
            isSubmitting = false;
        }

        return command == "hint" ? "Game hint requested." : "Answer submitted.";
    }

    private static UnityEngine.Object FindTerminal(object menus)
    {
        if (terminalType == null)
        {
            Type type = menus.GetType().Assembly.GetType("Screen", true);
            terminalFocus = type.GetField("screenHasFocus", PrivateInstance);
            terminalLocked = type.GetField("textInputIsLocked", PrivateInstance);
            answerBuffer = type.GetField("currentPassword", PrivateInstance);
            answerLength = type.GetField("passwordCharIndex", PrivateInstance);
            answerDisplay = type.GetField("displayText", PrivateInstance);
            resetAnswer = type.GetMethod("ResetPasswordToEmpty", PrivateInstance);
            updateInput = type.GetMethod("TextInputUpdate", PrivateInstance);
            terminalType = type;
        }

        UnityEngine.Object selected = null;
        foreach (UnityEngine.Object terminal in UnityEngine.Object.FindObjectsOfType(terminalType))
        {
            if (!(bool)terminalFocus.GetValue(terminal))
                continue;
            if (selected != null)
                throw new InvalidOperationException("Multiple answer terminals are active.");
            selected = terminal;
        }
        return selected;
    }
}
