using System;
using System.Linq;
using System.Reflection;
using PixelCrushers.DialogueSystem;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.UI;
using Object = UnityEngine.Object;

internal static class ClickMageEnding
{
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
    private static readonly FieldInfo CallingPortal = typeof(EndGameOutroManager).GetField("callingPortal", PrivateInstance);
    private static readonly FieldInfo YesCallback = typeof(UiAskPlayer).GetField("yesCallback", PrivateInstance);
    private static readonly MethodInfo Interact = typeof(PortalInteractable).GetMethod("Interact", PrivateInstance);
    private static readonly MethodInfo CanInteract = typeof(PortalInteractable).GetMethod("CanInteract", PrivateInstance);
    private static readonly MethodInfo InteractEnabled = typeof(PortalInteractable).GetMethod("InteractEnabled", PrivateInstance);

    private static Action<object> publishCompletion;
    private static Portal enteredPortal;
    private static int? portalId;
    private static bool leaveChosen;
    private static EndingReport completion;

    private sealed class EndingReport
    {
        public string phase;
        public string scene;
        public int? portalId;
        public bool portalFinished;
        public bool questionReady;
        public bool leaveChosen;
        public string conversation;
        public int? entryId;
        public bool waitingForContinue;
        public int responseCount;
        public bool completed;
        public string action;
        public int? endScreenComponentId;
    }

    internal static void TrackCompletion(Action<object> publisher)
    {
        if (publisher == null)
            throw new ArgumentNullException(nameof(publisher));
        if (publishCompletion == null)
            SceneManager.sceneLoaded += ObserveSceneLoaded;
        publishCompletion = publisher;
    }

    internal static object Status()
    {
        return completion ?? Observe();
    }

    internal static object Advance()
    {
        if (publishCompletion == null)
            throw new InvalidOperationException("Ending completion tracking is unavailable.");
        if (completion != null)
            return completion;

        var state = Observe();
        string action = null;
        if (Time.timeScale > 0)
        {
            switch (state.phase)
            {
                case "portal-ready":
                    if (PlayerInputManager.HasInstance && !PlayerInputManager.Instance.ControlsDisabled() &&
                        !DialogueManager.isConversationActive)
                    {
                        var target = FinishedPortal();
                        Interact.Invoke(target, null);
                        if ((Portal)CallingPortal.GetValue(EndGameOutroManager.Instance) != target.portal)
                            throw new InvalidOperationException("The stock outro did not accept this portal.");
                        enteredPortal = target.portal;
                        portalId = enteredPortal.GetInstanceID();
                        leaveChosen = false;
                        action = "enter-portal";
                    }
                    break;
                case "question-ready":
                    UiAskPlayer.Instance.YesNoPressed(true);
                    leaveChosen = true;
                    action = "choose-leave";
                    break;
                case "dialogue-ready":
                    ((AbstractDialogueUI)DialogueManager.dialogueUI).OnContinueConversation();
                    action = "continue-dialogue";
                    break;
                case "response-ready":
                    ReadyResponses(DialogueManager.currentConversationState).First().OnClick();
                    action = "select-response";
                    break;
            }
        }

        state = Observe();
        state.action = action;
        return state;
    }

    private static EndingReport Observe()
    {
        var activeScene = SceneManager.GetActiveScene();
        var report = new EndingReport {
            phase = "portal-incomplete", scene = activeScene.name
        };
        if (!EndGameOutroManager.HasInstance)
            return report;

        var outro = EndGameOutroManager.Instance;
        var linkedPortal = (Portal)CallingPortal.GetValue(outro);
        bool hasLeaveQuestion = HasLeaveQuestion(outro);
        bool controlsDisabled = PlayerInputManager.HasInstance && PlayerInputManager.Instance.ControlsDisabled();
        if (enteredPortal && !leaveChosen && !controlsDisabled && !hasLeaveQuestion)
        {
            enteredPortal = null;
            portalId = null;
        }
        if (!enteredPortal && linkedPortal && linkedPortal.gameObject.scene.name == "Island" &&
            linkedPortal.IsFinished() && (controlsDisabled || hasLeaveQuestion))
        {
            // Paying the final stage opens this same outro before another interaction is needed.
            enteredPortal = linkedPortal;
            portalId = linkedPortal.GetInstanceID();
            leaveChosen = false;
        }

        report.portalId = portalId;
        report.leaveChosen = leaveChosen;
        if (!enteredPortal)
        {
            var target = FinishedPortal();
            if (target)
            {
                report.portalId = target.portal.GetInstanceID();
                report.portalFinished = true;
                report.phase = "portal-ready";
            }
            return report;
        }

        report.portalFinished = enteredPortal.IsFinished();
        if (!report.portalFinished || linkedPortal != enteredPortal)
            return report;

        if (!leaveChosen)
        {
            report.questionReady = hasLeaveQuestion && LeaveQuestionReady();
            report.phase = report.questionReady ? "question-ready" : "waiting-question";
            return report;
        }

        report.phase = "waiting-cutscene";
        if (!DialogueManager.isConversationActive)
            return report;

        report.conversation = DialogueManager.lastConversationStarted;
        var dialogue = DialogueManager.currentConversationState;
        var entry = dialogue?.subtitle?.dialogueEntry;
        report.entryId = entry?.id;
        report.phase = "waiting-dialogue";
        if (!IsEndingDialogue(report.conversation) || entry == null ||
            entry.conversationID != DialogueManager.lastConversationID)
            return report;

        var view = DialogueManager.conversationView;
        var ui = DialogueManager.dialogueUI as AbstractDialogueUI;
        report.waitingForContinue = view && view.isWaitingForContinue;
        report.responseCount = dialogue.pcResponses?.Count(response => response.enabled) ?? 0;
        if (ui && ui.isOpen && report.waitingForContinue)
            report.phase = "dialogue-ready";
        else if (ui && ui.isOpen && report.responseCount > 0 && ReadyResponses(dialogue).Any())
            report.phase = "response-ready";
        return report;
    }

    private static PortalInteractable FinishedPortal()
    {
        return Object.FindObjectsByType<PortalInteractable>(FindObjectsSortMode.InstanceID)
            .FirstOrDefault(candidate => candidate.isActiveAndEnabled && candidate.portal &&
                candidate.portal.gameObject.scene.name == "Island" && candidate.portal.IsFinished() &&
                (bool)CanInteract.Invoke(candidate, null) && (bool)InteractEnabled.Invoke(candidate, null));
    }

    private static bool HasLeaveQuestion(EndGameOutroManager outro)
    {
        if (!UiAskPlayer.HasInstance)
            return false;
        return (Action)YesCallback.GetValue(UiAskPlayer.Instance) == new Action(outro.LeaveIsland);
    }

    private static bool LeaveQuestionReady()
    {
        var question = UiAskPlayer.Instance;
        return question.YesBtn && question.YesBtn.activeInHierarchy &&
            question.yesCanvasGrp && question.yesCanvasGrp.alpha >= 0.99f && question.yesCanvasGrp.interactable;
    }

    private static bool IsEndingDialogue(string title)
    {
        return title == "endGame_trader" || title == "endGame_obelisk";
    }

    private static StandardUIResponseButton[] ReadyResponses(ConversationState dialogue)
    {
        var responses = dialogue.pcResponses;
        return Object.FindObjectsByType<StandardUIResponseButton>(FindObjectsSortMode.InstanceID)
            .Where(button => button.isActiveAndEnabled && button.button && button.button.IsInteractable() &&
                button.response != null && button.response.enabled && responses.Contains(button.response))
            .ToArray();
    }

    private static void ObserveSceneLoaded(Scene scene, LoadSceneMode mode)
    {
        if (!leaveChosen || !portalId.HasValue || scene.name != "EndScreen" || !scene.isLoaded)
            return;

        var endScreen = scene.GetRootGameObjects()
            .Select(root => root.GetComponentInChildren<EndScreen>(true))
            .FirstOrDefault(screen => screen);
        completion = new EndingReport {
            phase = "completed", scene = scene.name, portalId = portalId, portalFinished = true,
            leaveChosen = true, completed = true, endScreenComponentId = endScreen ? endScreen.GetInstanceID() : (int?)null
        };
        try
        {
            publishCompletion(completion);
        }
        catch (Exception error)
        {
            Debug.LogError("ClickMageControl could not publish the observed EndScreen: " + error.GetBaseException().Message);
        }
    }
}
