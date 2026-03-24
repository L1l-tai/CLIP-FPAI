
def jaccardDistance(box1, box2):
    x1 = max(box1[0], box2[0])
    y1 = max(box1[1], box2[1])
    x2 = min(box1[0] + box1[2], box2[0] + box2[2])
    y2 = min(box1[1] + box1[3], box2[1] + box2[3])
    
    intersection_area = max(0, x2 - x1) * max(0, y2 - y1)
    box1_area = box1[2] * box1[3]
    box2_area = box2[2] * box2[3]
    
    union_area = box1_area + box2_area - intersection_area
    
    jaccard_distance = 1.0 - intersection_area / union_area
    
    return jaccard_distance

def soft_nms(box_list, score_list, id_list, conf=0.25, iou=0.45, NOC=80):
    nms_indices = []

    for class_id in range(NOC):
        score_index_vec = []
        for i in range(len(score_list)):
            if score_list[i] > conf and id_list[i] == class_id:
                score_index_vec.append((score_list[i], i))
        
        score_index_vec.sort(key=lambda x: x[0], reverse=True)
        
        # for i in range(len(score_index_vec)):
        #     idx = score_index_vec[i][1]
        #     keep = True
        #     for k in range(len(nms_indices)):
        #         if 1 - jaccardDistance(box_list[idx], box_list[nms_indices[k]]) > iou:
        #             keep = False
        #             break
        #     if keep:
        #         nms_indices.append(idx)
        # 修改为类内NMS
        class_nms_indices = []
        for i in range(len(score_index_vec)):
            idx = score_index_vec[i][1]
            keep = True
            for k in range(len(class_nms_indices)):
                if 1 - jaccardDistance(box_list[idx], box_list[class_nms_indices[k]]) > iou:
                    keep = False
                    break
            if keep:
                class_nms_indices.append(idx)

        nms_indices.extend(class_nms_indices)
    # get box,score,id based on nms_idx 
    box_list = [box_list[obj] for obj in nms_indices]
    nms_box_list = []
    for box in box_list:
        x0 = box[0]
        y0 = box[1]
        x1 = x0+box[2]
        y1 = y0+box[3]
        nms_box_list.append([x0,y0,x1,y1])
    nms_score_list = [score_list[obj] for obj in nms_indices]
    nms_cls_ids = [id_list[obj] for obj in nms_indices]
        
    return nms_indices,nms_box_list,nms_score_list,nms_cls_ids