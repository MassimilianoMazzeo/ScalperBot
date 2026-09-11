# ScalperBot
Modifiche Apportate al Codice:
Uscita su Rifiuto Rimossa: Eliminata completamente la logica che chiudeva l'operazione quando la candela creava una shadow/wick contraria. Ora l'operazione rimane aperta guidata unicamente dai target monetari e dagli stop loss a step.

Margine di Drawdown Esteso:

La piramidazione e lo Stop Loss a Break-Even (0€) scattano ancora a +2.50€, ma lasciando più respiro alla posizione per ritracciare prima di salire.

Gli scaglioni di protezione dello Stop Loss avanzano a step più distanziati e con maggiore tolleranza (+5.00€, +10.00€, fino al TP finale a +15.00€).

L'ampiezza e le tolleranze del filtro Range sono state ampliate per consentire al prezzo di oscillare senza chiudere subito in perdita se la parte opposta del box non viene colpita al primo impulso.
